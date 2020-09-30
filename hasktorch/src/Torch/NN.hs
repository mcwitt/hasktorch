{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

module Torch.NN where

import Control.Applicative (Applicative (liftA2))
import Control.Monad.State.Strict
import Data.Kind
import Data.Proxy
import Data.Type.Bool
import GHC.Generics
import GHC.TypeLits
import System.IO.Unsafe (unsafePerformIO)
import Torch.Autograd
import Torch.Functional
import Torch.Initializers
import Torch.Internal.Cast (cast3)
import qualified Torch.Internal.Managed.Native as ATen
import qualified Torch.Internal.Managed.Type.Tensor as ATen
import Torch.Tensor
import Torch.TensorFactories (ones', randIO', randnIO')

type Parameter = IndependentTensor

type ParamStream a = State [Parameter] a

nextParameter :: ParamStream Parameter
nextParameter = do
  params <- get
  case params of
    [] -> error "Not enough parameters supplied to replaceParameters"
    (p : t) -> do put t; return p

class HasForward f a where
  type B f a :: Type
  forward :: f -> a -> B f a

data ModelRandomness = Deterministic | Stochastic

-- TODO: remove placeholder random state 'G', replace with (typed version of):
-- https://github.com/hasktorch/hasktorch/blob/35e447da733c3430cd4a181c0e1d1b029b68e942/hasktorch/src/Torch/Random.hs#L38
data G

-- TODO: move to typelevel utils (maybe Torch.Typed.Aux?)
type family Contains (f :: k) (a :: Type) :: Bool where
  Contains a a = 'True
  Contains (f g) a = Contains f a || Contains g a
  Contains _ _ = 'False

type family ModelRandomnessR (out :: Type) :: (ModelRandomness, Type) where
  ModelRandomnessR (G -> (out, G)) =
    If
      (Contains out G)
      ( TypeError
          ( Text "For stochastic models, 'b' must not contain 'Generator' in "
              :<>: Text "'forward :: f -> a -> Generator -> (b, Generator)'."
          )
      )
      '( 'Stochastic, out)
  ModelRandomnessR out =
    If
      (Contains out G)
      ( TypeError
          ( Text "Stochastic models must have a forward pass of the form "
              :<>: Text "'forward :: f -> a -> Generator -> (b, Generator)'."
          )
      )
      '( 'Deterministic, out)

class HasForwardProduct (modelARandomness :: ModelRandomness) (modelBRandomness :: ModelRandomness) f1 a1 b1 f2 a2 b2 where
  type BProduct modelARandomness modelBRandomness f1 a1 b1 f2 a2 b2 :: Type
  forwardProduct ::
    Proxy modelARandomness ->
    Proxy modelBRandomness ->
    f1 ->
    a1 ->
    Proxy b1 ->
    f2 ->
    a2 ->
    Proxy b2 ->
    BProduct modelARandomness modelBRandomness f1 a1 b1 f2 a2 b2

class HasForwardSum (modelARandomness :: ModelRandomness) (modelBRandomness :: ModelRandomness) f1 a1 b1 f2 a2 b2 where
  type BSum modelARandomness modelBRandomness f1 a1 b1 f2 a2 b2 :: Type
  forwardSum ::
    Proxy modelARandomness ->
    Proxy modelBRandomness ->
    Either (f1, a1) (f2, a2) ->
    Proxy (b1, b2) ->
    BSum modelARandomness modelBRandomness f1 a1 b1 f2 a2 b2

--
-- Deterministic instances
--

instance
  ( HasForward modelA inA,
    B modelA inA ~ outA,
    HasForward modelB inB,
    B modelB inB ~ outB
  ) =>
  HasForwardProduct 'Deterministic 'Deterministic modelA inA outA modelB inB outB
  where
  type BProduct 'Deterministic 'Deterministic modelA inA outA modelB inB outB = (outA, outB)
  forwardProduct _ _ modelA inA _ modelB inB _ = (forward modelA inA, forward modelB inB)

instance (HasForward modelA inA, HasForward modelB inB) => HasForwardSum 'Deterministic 'Deterministic modelA inA outA modelB inB outB where
  type BSum 'Deterministic 'Deterministic modelA inA outA modelB inB outB = Either (B modelA inA) (B modelB inB)
  forwardSum _ _ (Left (modelA, inA)) _ = Left $ forward modelA inA
  forwardSum _ _ (Right (modelB, inB)) _ = Right $ forward modelB inB

--
-- Stochastic mixed instances
--

instance
  ( HasForward modelA inA,
    B modelA inA ~ (G -> (outA, G)),
    HasForward modelB inB,
    B modelB inB ~ outB
  ) =>
  HasForwardProduct 'Stochastic 'Deterministic modelA inA outA modelB inB outB
  where
  type BProduct 'Stochastic 'Deterministic modelA inA outA modelB inB outB = G -> ((outA, outB), G)
  forwardProduct _ _ modelA inA _ modelB inB _ = \g -> let (outA, g') = forward modelA inA g in ((outA, forward modelB inB), g')

instance
  ( HasForward modelA inA,
    B modelA inA ~ outA,
    HasForward modelB inB,
    B modelB inB ~ (G -> (outB, G))
  ) =>
  HasForwardProduct 'Deterministic 'Stochastic modelA inA outA modelB inB outB
  where
  type BProduct 'Deterministic 'Stochastic modelA inA outA modelB inB outB = G -> ((outA, outB), G)
  forwardProduct _ _ modelA inA _ modelB inB _ = \g -> let (outB, g') = forward modelB inB g in ((forward modelA inA, outB), g')

instance
  ( HasForward modelA inA,
    B modelA inA ~ (G -> (outA, G)),
    HasForward modelB inB,
    B modelB inB ~ outB
  ) =>
  HasForwardSum 'Stochastic 'Deterministic modelA inA outA modelB inB outB
  where
  type BSum 'Stochastic 'Deterministic modelA inA outA modelB inB outB = G -> (Either outA outB, G)
  forwardSum _ _ (Left (modelA, inA)) _ = \g -> let (outA, g') = forward modelA inA g in (Left outA, g')
  forwardSum _ _ (Right (modelB, inB)) _ = \g -> (Right $ forward modelB inB, g)

instance
  ( HasForward modelA inA,
    B modelA inA ~ outA,
    HasForward modelB inB,
    B modelB inB ~ (G -> (outB, G))
  ) =>
  HasForwardSum 'Deterministic 'Stochastic modelA inA outA modelB inB outB
  where
  type BSum 'Deterministic 'Stochastic modelA inA outA modelB inB outB = G -> (Either outA outB, G)
  forwardSum _ _ (Left (modelA, inA)) _ = \g -> (Left $ forward modelA inA, g)
  forwardSum _ _ (Right (modelB, inB)) _ = \g -> let (outA, g') = forward modelB inB g in (Right outA, g')

--
-- Fully-stochastic instances
--

instance
  ( HasForward modelA inA,
    B modelA inA ~ (G -> (outA, G)),
    HasForward modelB inB,
    B modelB inB ~ (G -> (outB, G))
  ) =>
  HasForwardProduct 'Stochastic 'Stochastic modelA inA outA modelB inB outB
  where
  type BProduct 'Stochastic 'Stochastic modelA inA outA modelB inB outB = G -> ((outA, outB), G)
  forwardProduct _ _ modelA inA _ modelB inB _ = runState $ do
    outA <- state (forward modelA inA)
    outB <- state (forward modelB inB)
    return (outA, outB)

instance
  ( HasForward modelA inA,
    B modelA inA ~ (G -> (outA, G)),
    HasForward modelB inB,
    B modelB inB ~ (G -> (outB, G))
  ) =>
  HasForwardSum 'Stochastic 'Stochastic modelA inA outA modelB inB outB
  where
  type BSum 'Stochastic 'Stochastic modelA inA outA modelB inB outB = G -> (Either outA outB, G)
  forwardSum _ _ (Left (modelA, inA)) _ = \g -> let (outA, g') = forward modelA inA g in (Left outA, g')
  forwardSum _ _ (Right (modelB, inB)) _ = \g -> let (outB, g') = forward modelB inB g in (Right outB, g')

-- TODO: move to Torch.Typed.Prelude?
type family Fst (t :: (k, k')) :: k where
  Fst '(x, _) = x

type family Snd (t :: (k, k')) :: k' where
  Snd '(_, y) = y

instance
  ( '(modelARandomness, outA) ~ ModelRandomnessR (B modelA inA),
    '(modelBRandomness, outB) ~ ModelRandomnessR (B modelB inB),
    HasForwardProduct modelARandomness modelBRandomness modelA inA outA modelB inB outB
  ) => HasForward (modelA, modelB) (inA, inB)
  where
  type
    B (modelA, modelB) (inA, inB) =
      BProduct
        (Fst (ModelRandomnessR (B modelA inA)))
        (Fst (ModelRandomnessR (B modelB inB)))
        modelA
        inA
        (Snd (ModelRandomnessR (B modelA inA)))
        modelB
        inB
        (Snd (ModelRandomnessR (B modelB inB)))
  forward (modelA, modelB) (inA, inB) =
    forwardProduct
      (Proxy :: Proxy modelARandomness)
      (Proxy :: Proxy modelBRandomness)
      modelA
      inA
      (Proxy :: Proxy outA)
      modelB
      inB
      (Proxy :: Proxy outB)

--
-- Parameterized
--

class Parameterized f where
  flattenParameters :: f -> [Parameter]
  default flattenParameters :: (Generic f, GParameterized (Rep f)) => f -> [Parameter]
  flattenParameters f = gFlattenParameters (from f)

  _replaceParameters :: f -> ParamStream f
  default _replaceParameters :: (Generic f, GParameterized (Rep f)) => f -> ParamStream f
  _replaceParameters f = to <$> _gReplaceParameters (from f)

replaceParameters :: Parameterized f => f -> [Parameter] -> f
replaceParameters f params =
  let (f', remaining) = runState (_replaceParameters f) params
   in if null remaining
        then f'
        else error "Some parameters in a call to replaceParameters haven't been consumed!"

instance Parameterized Tensor where
  flattenParameters _ = []
  _replaceParameters = return

instance Parameterized Parameter where
  flattenParameters = pure
  _replaceParameters _ = nextParameter

instance Parameterized Int where
  flattenParameters _ = []
  _replaceParameters = return

instance Parameterized Float where
  flattenParameters _ = []
  _replaceParameters = return

instance Parameterized Double where
  flattenParameters _ = []
  _replaceParameters = return

instance Parameterized (a -> a) where
  flattenParameters _ = []
  _replaceParameters = return

class GParameterized f where
  gFlattenParameters :: forall a. f a -> [Parameter]
  _gReplaceParameters :: forall a. f a -> ParamStream (f a)

instance GParameterized U1 where
  gFlattenParameters U1 = []
  _gReplaceParameters U1 = return U1

instance (GParameterized f, GParameterized g) => GParameterized (f :+: g) where
  gFlattenParameters (L1 x) = gFlattenParameters x
  gFlattenParameters (R1 x) = gFlattenParameters x
  _gReplaceParameters (L1 x) = do
    x' <- _gReplaceParameters x
    return $ L1 x'
  _gReplaceParameters (R1 x) = do
    x' <- _gReplaceParameters x
    return $ R1 x'

instance (GParameterized f, GParameterized g) => GParameterized (f :*: g) where
  gFlattenParameters (x :*: y) = gFlattenParameters x ++ gFlattenParameters y
  _gReplaceParameters (x :*: y) = do
    x' <- _gReplaceParameters x
    y' <- _gReplaceParameters y
    return $ x' :*: y'

instance (Parameterized c) => GParameterized (K1 i c) where
  gFlattenParameters (K1 x) = flattenParameters x
  _gReplaceParameters (K1 x) = do
    x' <- _replaceParameters x
    return $ K1 x'

instance (GParameterized f) => GParameterized (M1 i t f) where
  gFlattenParameters (M1 x) = gFlattenParameters x
  _gReplaceParameters (M1 x) = do
    x' <- _gReplaceParameters x
    return $ M1 x'

class Randomizable spec f | spec -> f where
  sample :: spec -> IO f

--
-- Linear FC Layer
--

data LinearSpec = LinearSpec
  { in_features :: Int,
    out_features :: Int
  }
  deriving (Show, Eq)

data Linear = Linear
  { weight :: Parameter,
    bias :: Parameter
  }
  deriving (Show, Generic, Parameterized)

instance Parameterized [Linear]

linear :: Linear -> Tensor -> Tensor
linear layer input = linear' input w b
  where
    linear' input weight bias = unsafePerformIO $ (cast3 ATen.linear_ttt) input weight bias
    w = toDependent (weight layer)
    b = toDependent (bias layer)

linearForward :: Linear -> Tensor -> Tensor
linearForward = linear -- temporary alias until dependencies are updated

instance Randomizable LinearSpec Linear where
  sample LinearSpec {..} = do
    w <-
      makeIndependent
        =<< kaimingUniform
          FanIn
          (LeakyRelu $ Prelude.sqrt (5.0 :: Float))
          [out_features, in_features]
    init <- randIO' [out_features]
    let bound =
          (1 :: Float)
            / Prelude.sqrt
              ( fromIntegral
                  ( getter FanIn $
                      calculateFan
                        [ out_features,
                          in_features
                        ]
                  ) ::
                  Float
              )
    b <-
      makeIndependent
        =<< pure
          ( subScalar bound $ mulScalar (bound * 2.0) init
          )

    return $ Linear w b

--
-- Conv2d
--

data Conv2dSpec = Conv2dSpec
  { inputChannelSize :: Int,
    outputChannelSize :: Int,
    kernelHeight :: Int,
    kernelWidth :: Int
  }
  deriving (Show, Eq)

data Conv2d = Conv2d
  { conv2dWeight :: Parameter,
    conv2dBias :: Parameter
  }
  deriving (Show, Generic, Parameterized)

conv2dForward :: Conv2d -> (Int, Int) -> (Int, Int) -> Tensor -> Tensor
conv2dForward layer stride padding input =
  Torch.Functional.conv2d' w b stride padding input
  where
    w = toDependent (conv2dWeight layer)
    b = toDependent (conv2dBias layer)

instance Randomizable Conv2dSpec Conv2d where
  sample Conv2dSpec {..} = do
    w <-
      makeIndependent
        =<< kaimingUniform
          FanIn
          (LeakyRelu $ Prelude.sqrt (5.0 :: Float))
          [ outputChannelSize,
            inputChannelSize,
            kernelHeight,
            kernelWidth
          ]
    init <- randIO' [outputChannelSize]
    let bound =
          (1 :: Float)
            / Prelude.sqrt
              ( fromIntegral
                  ( getter FanIn $
                      calculateFan
                        [ outputChannelSize,
                          inputChannelSize,
                          kernelHeight,
                          kernelWidth
                        ]
                  ) ::
                  Float
              )
    b <-
      makeIndependent
        =<< pure
          ( subScalar bound $ mulScalar (bound * 2.0) init
          )

    return $ Conv2d w b
