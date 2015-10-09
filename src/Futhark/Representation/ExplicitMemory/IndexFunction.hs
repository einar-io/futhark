{-# LANGUAGE GADTs, DataKinds, TypeOperators, KindSignatures, ScopedTypeVariables #-}
module Futhark.Representation.ExplicitMemory.IndexFunction
       (
         IxFun
       , Shape
       , ShapeChange
       , Indices
       , index
       , iota
       , offsetIndex
       , permute
       , reshape
       , stripe
       , unstripe
       , applyInd
       , offsetUnderlying
       , underlyingOffset
       , codomain
       , shape
       , linearWithOffset
       , rearrangeWithOffset
       )
       where

import Data.Constraint (Dict (..))
import Data.Type.Natural hiding (n1,n2)
import Data.Vector.Sized hiding (index, map)
import qualified Data.Vector.Sized as Vec
import Proof.Equational
import Data.Monoid
import Data.Type.Equality hiding (outer)

import Prelude hiding (div, quot)

import Futhark.Transform.Substitute
import Futhark.Transform.Rename

import Futhark.Representation.AST.Syntax (DimChange (..))
import qualified Futhark.Representation.ExplicitMemory.Permutation as Perm
import Futhark.Representation.ExplicitMemory.SymSet (SymSet)
import Futhark.Representation.AST.Attributes.Names
import Futhark.Representation.AST.Attributes.Reshape hiding (sliceSizes)
import Futhark.Representation.AST.Attributes.Stripe
import Futhark.Util.IntegralExp

import Text.PrettyPrint.Mainland

type Shape num = Vector num
type ShapeChange num = Vector (DimChange num)
type Indices num = Vector num

data IxFun :: * -> Nat -> * where
  Direct :: num -> Shape num n -> IxFun num n
  Offset :: IxFun num n -> num -> IxFun num n
  Permute :: IxFun num n -> Perm.Permutation n -> IxFun num n
  Index :: SNat n -> IxFun num (m:+:n) -> Indices num m -> IxFun num n
  Reshape :: IxFun num ('S m) -> ShapeChange num n -> IxFun num n
  Stripe :: IxFun num n -> num -> IxFun num n
  Unstripe :: IxFun num n -> num -> IxFun num n

--- XXX: this is almost just structural equality, which may be too
--- conservative - unless we normalise first, somehow.
instance (IntegralCond num, Eq num) => Eq (IxFun num n) where
  Direct offset1 _ == Direct offset2 _ =
    offset1 == offset2
  Offset ixfun1 offset1 == Offset ixfun2 offset2 =
    ixfun1 == ixfun2 && offset1 == offset2
  Permute ixfun1 perm1 == Permute ixfun2 perm2 =
    ixfun1 == ixfun2 && perm1 == perm2
  Index _ (ixfun1 :: IxFun num (m1 :+: n)) (is1 :: Indices nun m1)
    == Index _ (ixfun2 :: IxFun num (m2 :+: n)) (is2 :: Indices num m2) =
    case testEquality m1' m2' of
      Nothing -> False
      Just Refl ->
        ixfun1 == ixfun2 &&
        Vec.toList is1 == Vec.toList is2
    where m1' :: SNat m1
          m1' = Vec.sLength is1
          m2' :: SNat m2
          m2' = Vec.sLength is2
  Reshape ixfun1 shape1 == Reshape ixfun2 shape2 =
    case testEquality (rank ixfun1) (rank ixfun2) of
      Just Refl ->
        ixfun1 == ixfun2 && Vec.length shape1 == Vec.length shape2
      _ -> False
  Stripe ixfun1 stride1 == Stripe ixfun2 stride2 =
    case testEquality (rank ixfun1) (rank ixfun2) of
      Just Refl ->
        ixfun1 == ixfun2 && stride1 == stride2
      _ -> False
  Unstripe ixfun1 stride1 == Unstripe ixfun2 stride2 =
    case testEquality (rank ixfun1) (rank ixfun2) of
      Just Refl ->
        ixfun1 == ixfun2 && stride1 == stride2
      _ -> False
  _ == _ = False

instance Show num => Show (IxFun num n) where
  show (Direct offset n) = "Direct (" ++ show offset ++ "," ++ show n ++ ")"
  show (Offset fun k) = "Offset (" ++ show fun ++ ", " ++ show k ++ ")"
  show (Permute fun perm) = "Permute (" ++ show fun ++ ", " ++ show perm ++ ")"
  show (Index _ fun is) = "Index (" ++ show fun ++ ", " ++ show is ++ ")"
  show (Reshape fun newshape) = "Reshape (" ++ show fun ++ ", " ++ show newshape ++ ")"
  show (Stripe fun stride) = "Stripe (" ++ show fun ++ ", " ++ show stride ++ ")"
  show (Unstripe fun stride) = "Unstripe (" ++ show fun ++ ", " ++ show stride ++ ")"

instance Pretty num => Pretty (IxFun num n) where
  ppr (Direct offset dims) =
    text "Direct" <> parens (commasep $ ppr offset : map ppr (Vec.toList dims))
  ppr (Offset fun k) = ppr fun <+> text "+" <+> ppr k
  ppr (Permute fun perm) = ppr fun <> ppr perm
  ppr (Index _ fun is) = ppr fun <> brackets (commasep $ map ppr $ Vec.toList is)
  ppr (Reshape fun oldshape) =
    ppr fun <> text "->" <>
    parens (commasep (map ppr $ Vec.toList oldshape))
  ppr (Stripe fun stride) =
    ppr fun <> text "->+" <> ppr stride
  ppr (Unstripe fun stride) =
    ppr fun <> text "->-" <> ppr stride

instance (Eq num, IntegralCond num, Substitute num) => Substitute (IxFun num n) where
  substituteNames subst (Direct offset n) =
    Direct (substituteNames subst offset) n
  substituteNames subst (Offset fun k) =
    Offset (substituteNames subst fun) (substituteNames subst k)
  substituteNames subst (Permute fun perm) =
    Permute (substituteNames subst fun) perm
  substituteNames subst (Index n fun is) =
    Index n
    (substituteNames subst fun)
    (Vec.map (substituteNames subst) is)
  substituteNames subst (Reshape fun newshape) =
    reshape
    (substituteNames subst fun)
    (Vec.map (substituteNames subst) newshape)
  substituteNames subst (Stripe fun stride) =
    stripe (substituteNames subst fun) stride
  substituteNames subst (Unstripe fun stride) =
    unstripe (substituteNames subst fun) stride

instance (Eq num, IntegralCond num, Substitute num, Rename num) => Rename (IxFun num n) where
  -- Because there is no mapM-like function on sized vectors, we
  -- implement renaming by retrieving the substitution map, then using
  -- 'substituteNames'.  This is safe as index functions do not
  -- contain their own bindings.
  rename ixfun = do
    subst <- renamerSubstitutions
    return $ substituteNames subst ixfun

index :: forall (n::Nat) num. IntegralCond num =>
         IxFun num ('S n) -> Indices num ('S n) -> num -> num

index (Direct offset dims) is element_size =
  (Vec.sum (Vec.zipWithSame (*) is slicesizes) * element_size) + offset
  where slicesizes = Vec.tail $ sliceSizes dims

index (Offset fun offset) (i :- is) element_size =
  index fun ((i + offset) :- is) element_size

index (Permute fun perm) is_new element_size =
  index fun is_old element_size
  where is_old = Perm.apply (Perm.invert perm) is_new

index (Index _ fun (is1::Indices num m)) is2 element_size =
  case (singInstance $ sLength is1,
        singInstance $ sLength is2 %:- sOne) of
    (SingInstance,SingInstance) ->
      let is = is1 `Vec.append` is2
          outer = succPlusR (sing :: SNat m) (sing :: SNat n)
          proof :: (m :+ 'S n) :=: 'S (m :+ n)
          proof = succPlusR (sing :: SNat m) (sing :: SNat n)
      in case singInstance $ coerce proof (sLength is) %:- sOne of
        SingInstance ->
          index (coerce outer fun) (coerce outer is) element_size

index (Reshape (fun :: IxFun num ('S m)) newshape) is element_size =
  -- First, compute a flat index based on the new shape.  Then, turn
  -- that into an index set for the inner index function and apply the
  -- inner index function to that set.
  let oldshape = shape fun
      flatidx = computeFlatIndex (Vec.map newDim newshape) is
      innerslicesizes = Vec.tail $ sliceSizes oldshape
      new_indices = computeNewIndices innerslicesizes flatidx
  in index fun new_indices element_size

index (Stripe fun stride) (i :- is) element_size =
  index fun (stripeIndex (stripeToNumBlocks i_n stride) i :- is) element_size
  where i_n = Vec.head $ shape fun

index (Unstripe fun stride) (i :- is) element_size =
  index fun (stripeIndexInverse (stripeToNumBlocks i_n stride) i :- is) element_size
  where i_n = Vec.head $ shape fun

computeNewIndices :: IntegralCond num =>
                     Vector num k -> num -> Indices num k
computeNewIndices Nil _ =
  Nil
computeNewIndices (size :- slices) i =
  (i `quot` size) :-
  computeNewIndices slices (i - (i `quot` size) * size)

computeFlatIndex :: IntegralCond num =>
                    Shape num ('S k) -> Indices num ('S k) -> num
computeFlatIndex dims is =
  flattenIndex (Vec.toList dims) (Vec.toList is)

sliceSizes :: IntegralCond num =>
              Shape num m -> Vector num ('S m)
sliceSizes Nil =
  singleton 1
sliceSizes (n :- ns) =
  Vec.product (n :- ns) :-
  sliceSizes ns

iota :: IntegralCond num =>
        Shape num n -> IxFun num n
iota = Direct 0

offsetIndex :: IntegralCond num =>
               IxFun num n -> num -> IxFun num n
offsetIndex = Offset

permute :: IntegralCond num =>
           IxFun num n -> Perm.Permutation n -> IxFun num n
permute (Permute ixfun oldperm) perm
  | Perm.invert oldperm == perm = ixfun
permute ixfun perm = Permute ixfun perm

reshape :: forall num m n.(Eq num, IntegralCond num) =>
           IxFun num ('S m) -> ShapeChange num n -> IxFun num n
reshape (Direct offset _) newshape =
  Direct offset $ Vec.map newDim newshape
reshape (Reshape ixfun _) newshape =
  reshape ixfun newshape
reshape ixfun newshape =
  case rank ixfun `testEquality` Vec.sLength newshape of
    Just Refl
      | shape ixfun == Vec.map newDim newshape ->
      ixfun
      | Just _ <- shapeCoercion $ Vec.toList newshape ->
        case ixfun of
          Permute ixfun' perm ->
            Permute (reshape ixfun' $ Perm.apply (Perm.invert perm) newshape) perm

          Offset ixfun' offset ->
            Offset (reshape ixfun' newshape) offset

          Stripe ixfun' stride ->
            Stripe (reshape ixfun' newshape) stride

          Unstripe ixfun' stride ->
            Unstripe (reshape ixfun' newshape) stride

          Index sm (ixfun' :: IxFun num (k :+: 'S m)) (is :: Indices num k)
            | Dict <- propToBoolLeq $ plusLeqL (Vec.sLength is) sm ->
            let ixfun'' :: IxFun num ('S (k :+: m))
                ixfun'' = coerce (sym $ plusSR (Vec.sLength is) (sm %- sOne)) ixfun'
                unchanged_shape :: ShapeChange num k
                unchanged_shape =
                  Vec.map DimCoercion $ Vec.take (Vec.sLength is) $ shape ixfun'
                newshape' :: ShapeChange num (k :+: 'S m)
                newshape' = Vec.append unchanged_shape newshape
            in Index sm (reshape ixfun'' newshape') is

          Reshape _ _ ->
            Reshape ixfun newshape

          Direct offset _ ->
            Direct offset $ Vec.map newDim newshape
    _ ->
      Reshape ixfun newshape

stripe :: forall num n.(Eq num, IntegralCond num) =>
          IxFun num n -> num -> IxFun num n
stripe = Stripe

unstripe :: forall num n.(Eq num, IntegralCond num) =>
            IxFun num n -> num -> IxFun num n
unstripe = Unstripe

applyInd :: forall num n m.
            IntegralCond num =>
            SNat n -> IxFun num (m:+:n) -> Indices num m -> IxFun num n
applyInd n (Index m_plus_n (ixfun :: IxFun num (k:+:(m:+:n))) (mis :: Indices num k)) is =
  Index n ixfun' is'
  where k :: SNat k
        k = Vec.sLength mis
        m :: SNat m
        m = case propToBoolLeq $ plusLeqR m n of
              Dict -> coerce (plusMinusEqL m n) $ m_plus_n %- n
        is' :: Indices num (m:+:k)
        is' = coerce (plusCommutative k m) $ Vec.append mis is
        ixfun' :: IxFun num ((m:+:k):+:n)
        ixfun' = coerce (plusCongR n (plusCommutative k m)) $
                 coerce (plusAssociative k m n) ixfun
applyInd n ixfun is = Index n ixfun is

offsetUnderlying :: IntegralCond num =>
                    IxFun num n -> num -> IxFun num n
offsetUnderlying (Direct offset dims) k =
  Direct (offset + k) dims
offsetUnderlying (Offset ixfun m) k =
  Offset (offsetUnderlying ixfun k) m
offsetUnderlying (Permute ixfun perm) k =
  Permute (offsetUnderlying ixfun k) perm
offsetUnderlying (Index n ixfun is) k =
  Index n (offsetUnderlying ixfun k) is
offsetUnderlying (Reshape ixfun dims) k =
  Reshape (offsetUnderlying ixfun k) dims
offsetUnderlying (Stripe ixfun stride) k =
  Stripe (offsetUnderlying ixfun k) stride
offsetUnderlying (Unstripe ixfun stride) k =
  Unstripe (offsetUnderlying ixfun k) stride

underlyingOffset :: IntegralCond num =>
                    IxFun num n -> num
underlyingOffset (Direct offset _) =
  offset
underlyingOffset (Offset ixfun _) =
  underlyingOffset ixfun
underlyingOffset (Permute ixfun _) =
  underlyingOffset ixfun
underlyingOffset (Index _ ixfun _) =
  underlyingOffset ixfun
underlyingOffset (Reshape ixfun _) =
  underlyingOffset ixfun
underlyingOffset (Stripe ixfun _) =
  underlyingOffset ixfun
underlyingOffset (Unstripe ixfun _) =
  underlyingOffset ixfun

codomain :: IntegralCond num =>
            IxFun num n -> SymSet n
codomain = undefined

rank :: IntegralCond num =>
        IxFun num n -> SNat n
rank (Direct _ dims) = sLength dims
rank (Offset ixfun _) = rank ixfun
rank (Permute ixfun _) = rank ixfun
rank (Index n _ _) = n
rank (Reshape _ newshape) = sLength newshape
rank (Stripe ixfun _) =
  rank ixfun
rank (Unstripe ixfun _) =
  rank ixfun

shape :: IntegralCond num =>
         IxFun num n -> Shape num n
shape (Direct _ dims) =
  dims
shape (Permute ixfun perm) =
  Perm.apply perm $ shape ixfun
shape (Offset ixfun _) =
  shape ixfun
shape (Index n (ixfun::IxFun num (m :+ n)) (indices::Indices num m)) =
  let ixfunshape :: Shape num (m :+ n)
      ixfunshape = shape ixfun
      islen :: SNat m
      islen = Vec.sLength indices
      prop :: Leq m (m :+ n)
      prop = plusLeqL islen n
      prop2 :: ((m :+: n) :-: m) :=: n
      prop2 = plusMinusEqR n islen
  in
   case (propToBoolLeq prop, prop2) of
     (Dict,Refl) ->
       let resshape :: Shape num ((m :+ n) :- m)
           resshape = Vec.drop islen ixfunshape
       in resshape
shape (Reshape _ dims) =
  Vec.map newDim dims
shape (Stripe ixfun _) =
  shape ixfun
shape (Unstripe ixfun _) =
  shape ixfun

-- This function does not cover all possible cases.  It's a "best
-- effort" kind of thing.
linearWithOffset :: forall n num. IntegralCond num =>
                    IxFun num n -> num -> Maybe num
linearWithOffset (Direct offset _) _ =
  Just offset
linearWithOffset (Offset ixfun n) element_size = do
  inner_offset <- linearWithOffset ixfun element_size
  case Vec.tail $ sliceSizes $ shape ixfun of
    Nil -> Nothing
    rowslice :- _ ->
      return $ inner_offset + (n * rowslice * element_size)
linearWithOffset (Reshape ixfun _) element_size =
 linearWithOffset ixfun element_size
linearWithOffset (Index n ixfun (is :: Indices num m)) element_size = do
  inner_offset <- linearWithOffset ixfun element_size
  case propToBoolLeq $ plusLeqL m n of
    Dict ->
      let slices :: Vector num m
          slices = Vec.take m $ Vec.tail $ sliceSizes $ shape ixfun
      in Just $ inner_offset + Vec.sum (Vec.zipWith (*) slices is) * element_size
  where m :: SNat m
        m = Vec.sLength is
linearWithOffset _ _ = Nothing

rearrangeWithOffset :: forall n num. IntegralCond num =>
                       IxFun num n -> Maybe (num, Perm.Permutation n)
rearrangeWithOffset (Permute (Direct offset _) perm) =
  Just (offset, perm)
rearrangeWithOffset _ =
  Nothing

instance FreeIn num => FreeIn (IxFun num n) where
  freeIn (Direct offset dims) = freeIn offset <> freeIn (Vec.toList dims)
  freeIn (Offset ixfun e) = freeIn ixfun <> freeIn e
  freeIn (Permute ixfun _) = freeIn ixfun
  freeIn (Index _ ixfun is) =
    freeIn ixfun <>
    mconcat (map freeIn $ toList is)
  freeIn (Reshape ixfun dims) =
    freeIn ixfun <> mconcat (map freeIn $ Vec.toList dims)
  freeIn (Stripe ixfun stride) =
    freeIn ixfun <> freeIn stride
  freeIn (Unstripe ixfun stride) =
    freeIn ixfun <> freeIn stride
