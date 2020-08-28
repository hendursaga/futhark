{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A primitive expression is an expression where the non-leaves are
-- primitive operators.  Our representation does not guarantee that
-- the expression is type-correct.
module Futhark.Analysis.PrimExp
  ( PrimExp (..)
  , evalPrimExp
  , primExpType
  , primExpSizeAtLeast
  , coerceIntPrimExp
  , leafExpTypes
  , true
  , false
  , constFoldPrimExp

  , module Futhark.IR.Primitive
  , sExt, zExt
  , (.&&.), (.||.), (.<.), (.<=.), (.>.), (.>=.), (.==.), (.&.), (.|.), (.^.)
  ) where

import Prelude hiding ((.), id)
import GHC.Generics (Generic)
import Language.SexpGrammar as Sexp
import Language.SexpGrammar.Generic
import Control.Category
import           Control.Monad
import           Data.Traversable
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T

import           Futhark.IR.Prop.Names
import           Futhark.IR.Primitive
import           Futhark.Util.IntegralExp
import           Futhark.Util.Pretty

-- | A primitive expression parametrised over the representation of
-- free variables.  Note that the 'Functor', 'Traversable', and 'Num'
-- instances perform automatic (but simple) constant folding.
--
-- Note also that the 'Num' instance assumes 'OverflowUndef'
-- semantics!
data PrimExp v = LeafExp v PrimType
               | ValueExp PrimValue
               | BinOpExp BinOp (PrimExp v) (PrimExp v)
               | CmpOpExp CmpOp (PrimExp v) (PrimExp v)
               | UnOpExp UnOp (PrimExp v)
               | ConvOpExp ConvOp (PrimExp v)
               | FunExp String [PrimExp v] PrimType
               deriving (Ord, Show, Generic)

instance SexpIso v => SexpIso (PrimExp v) where
  sexpIso = match
    $ With (. Sexp.list (Sexp.el (Sexp.sym "leaf") >>> Sexp.el sexpIso >>> Sexp.el sexpIso))
    $ With (. Sexp.list (Sexp.el (Sexp.sym "value") >>> Sexp.el sexpIso))
    $ With (. Sexp.list (Sexp.el (Sexp.sym "bin-op") >>> Sexp.el sexpIso >>> Sexp.el sexpIso >>> Sexp.el sexpIso))
    $ With (. Sexp.list (Sexp.el (Sexp.sym "cmp-op") >>> Sexp.el sexpIso >>> Sexp.el sexpIso >>> Sexp.el sexpIso))
    $ With (. Sexp.list (Sexp.el (Sexp.sym "un-op") >>> Sexp.el sexpIso >>> Sexp.el sexpIso))
    $ With (. Sexp.list (Sexp.el (Sexp.sym "conv-op") >>> Sexp.el sexpIso >>> Sexp.el sexpIso))
    $ With (. Sexp.list (Sexp.el (Sexp.sym "fun") >>> Sexp.el (iso T.unpack T.pack . sexpIso) >>> Sexp.el sexpIso >>> Sexp.el sexpIso))
    End

-- The Eq instance upcoerces all integer constants to their largest
-- type before comparing for equality.  This is technically not a good
-- idea, but solves annoying problems related to the Num instance
-- always producing Int64s.
instance Eq v => Eq (PrimExp v) where
  LeafExp x xt == LeafExp y yt = x == y && xt == yt
  ValueExp (IntValue x) == ValueExp (IntValue y) =
    intToInt64 x == intToInt64 y
  ValueExp x == ValueExp y =
    x == y
  BinOpExp xop x1 x2 == BinOpExp yop y1 y2 =
    xop == yop && x1 == y1 && x2 == y2
  CmpOpExp xop x1 x2 == CmpOpExp yop y1 y2 =
    xop == yop && x1 == y1 && x2 == y2
  UnOpExp xop x == UnOpExp yop y =
    xop == yop && x == y
  ConvOpExp xop x == ConvOpExp yop y =
    xop == yop && x == y
  FunExp xf xargs _ == FunExp yf yargs _ =
    xf == yf && xargs == yargs
  _ == _ = False

instance Functor PrimExp where
  fmap = fmapDefault

instance Foldable PrimExp where
  foldMap = foldMapDefault

instance Traversable PrimExp where
  traverse f (LeafExp v t) =
    LeafExp <$> f v <*> pure t
  traverse _ (ValueExp v) =
    pure $ ValueExp v
  traverse f (BinOpExp op x y) =
    constFoldPrimExp <$> (BinOpExp op <$> traverse f x <*> traverse f y)
  traverse f (CmpOpExp op x y) =
    CmpOpExp op <$> traverse f x <*> traverse f y
  traverse f (ConvOpExp op x) =
    ConvOpExp op <$> traverse f x
  traverse f (UnOpExp op x) =
    UnOpExp op <$> traverse f x
  traverse f (FunExp h args t) =
    FunExp h <$> traverse (traverse f) args <*> pure t

instance FreeIn v => FreeIn (PrimExp v) where
  freeIn' = foldMap freeIn'

-- | True if the 'PrimExp' has at least this many nodes.  This can be
-- much more efficient than comparing with 'length' for large
-- 'PrimExp's, as this function is lazy.
primExpSizeAtLeast :: Int -> PrimExp v -> Bool
primExpSizeAtLeast k = maybe True (>=k) . descend 0
  where descend i _
          | i >= k = Nothing
        descend i LeafExp{} = Just (i+1)
        descend i ValueExp{} = Just (i+1)
        descend i (BinOpExp _ x y) = do x' <- descend (i+1) x
                                        descend x' y
        descend i (CmpOpExp _ x y) = do x' <- descend (i+1) x
                                        descend x' y
        descend i (ConvOpExp _ x) = descend (i+1) x
        descend i (UnOpExp _ x) = descend (i+1) x
        descend i (FunExp _ args _) = foldM descend (i+1) args

-- | Perform quick and dirty constant folding on the top level of a
-- PrimExp.  This is necessary because we want to consider
-- e.g. equality modulo constant folding.
constFoldPrimExp :: PrimExp v -> PrimExp v
constFoldPrimExp (BinOpExp Add{} x y)
  | zeroIshExp x = y
  | zeroIshExp y = x
constFoldPrimExp (BinOpExp Sub{} x y)
  | zeroIshExp y = x
constFoldPrimExp (BinOpExp Mul{} x y)
  | oneIshExp x = y
  | oneIshExp y = x
  | zeroIshExp x, IntType it <- primExpType y =
      ValueExp $ IntValue $ intValue it (0::Int)
  | zeroIshExp y, IntType it <- primExpType x =
      ValueExp $ IntValue $ intValue it (0::Int)
constFoldPrimExp (BinOpExp SDiv{} x y)
  | oneIshExp y = x
constFoldPrimExp (BinOpExp SQuot{} x y)
  | oneIshExp y = x
constFoldPrimExp (BinOpExp UDiv{} x y)
  | oneIshExp y = x
constFoldPrimExp (BinOpExp bop (ValueExp x) (ValueExp y))
  | Just z <- doBinOp bop x y =
      ValueExp z
constFoldPrimExp (BinOpExp LogAnd x y)
  | oneIshExp x = y
  | oneIshExp y = x
  | zeroIshExp x = x
  | zeroIshExp y = y
constFoldPrimExp (BinOpExp LogOr x y)
  | oneIshExp x = x
  | oneIshExp y = y
  | zeroIshExp x = y
  | zeroIshExp y = x
constFoldPrimExp e = e

-- The Num instance performs a little bit of magic: whenever an
-- expression and a constant is combined with a binary operator, the
-- type of the constant may be changed to be the type of the
-- expression, if they are not already the same.  This permits us to
-- write e.g. @x * 4@, where @x@ is an arbitrary PrimExp, and have the
-- @4@ converted to the proper primitive type.  We also support
-- converting integers to floating point values, but not the other way
-- around.  All numeric instances assume unsigned integers for such
-- conversions.
--
-- We also perform simple constant folding, in particular to reduce
-- expressions to constants so that the above works.  However, it is
-- still a bit of a hack.
instance Pretty v => Num (PrimExp v) where
  x + y | Just z <- msum [asIntOp (`Add` OverflowUndef) x y,
                          asFloatOp FAdd x y] = constFoldPrimExp z
        | otherwise = numBad "+" (x,y)

  x - y | Just z <- msum [asIntOp (`Sub` OverflowUndef) x y,
                          asFloatOp FSub x y] = constFoldPrimExp z
        | otherwise = numBad "-" (x,y)

  x * y | Just z <- msum [asIntOp (`Mul` OverflowUndef) x y,
                          asFloatOp FMul x y] = constFoldPrimExp z
        | otherwise = numBad "*" (x,y)

  abs x | IntType t <- primExpType x = UnOpExp (Abs t) x
        | FloatType t <- primExpType x = UnOpExp (FAbs t) x
        | otherwise = numBad "abs" x

  signum x | IntType t <- primExpType x = UnOpExp (SSignum t) x
           | otherwise = numBad "signum" x

  fromInteger = fromInt32 . fromInteger

instance Pretty v => Fractional (PrimExp v) where
  x / y | Just z <- msum [asFloatOp FDiv x y] = constFoldPrimExp z
        | otherwise = numBad "/" (x,y)

  fromRational = ValueExp . FloatValue . Float64Value . fromRational

instance Pretty v => IntegralExp (PrimExp v) where
  x `div` y | Just z <- msum [asIntOp (`SDiv` Unsafe) x y,
                              asFloatOp FDiv x y] =
                constFoldPrimExp z
            | otherwise = numBad "div" (x,y)

  x `mod` y | Just z <- msum [asIntOp (`SMod` Unsafe) x y] = z
            | otherwise = numBad "mod" (x,y)

  x `quot` y | oneIshExp y = x
             | Just z <- msum [asIntOp (`SQuot` Unsafe) x y] = constFoldPrimExp z
             | otherwise = numBad "quot" (x,y)

  x `rem` y | Just z <- msum [asIntOp (`SRem` Unsafe) x y] = constFoldPrimExp z
            | otherwise = numBad "rem" (x,y)

  x `divUp` y | Just z <- msum [asIntOp (`SDivUp` Unsafe) x y] =
                  constFoldPrimExp z
              | otherwise = numBad "divRoundingUp" (x,y)

  sgn (ValueExp (IntValue i)) = Just $ signum $ valueIntegral i
  sgn _ = Nothing

  fromInt8  = ValueExp . IntValue . Int8Value
  fromInt16 = ValueExp . IntValue . Int16Value
  fromInt32 = ValueExp . IntValue . Int32Value
  fromInt64 = ValueExp . IntValue . Int64Value

-- | Lifted logical conjunction.
(.&&.) :: PrimExp v -> PrimExp v -> PrimExp v
x .&&. y = constFoldPrimExp $ BinOpExp LogAnd x y

-- | Lifted logical conjunction.
(.||.) :: PrimExp v -> PrimExp v -> PrimExp v
x .||. y = constFoldPrimExp $ BinOpExp LogOr x y

-- | Lifted relational operators; assuming signed numbers in case of
-- integers.
(.<.), (.>.), (.<=.), (.>=.), (.==.) :: PrimExp v -> PrimExp v -> PrimExp v
x .<. y = constFoldPrimExp $
          CmpOpExp cmp x y where cmp = case primExpType x of
                                         IntType t -> CmpSlt $ t `min` primExpIntType y
                                         FloatType t -> FCmpLt t
                                         _ -> CmpLlt
x .<=. y = constFoldPrimExp $
           CmpOpExp cmp x y where cmp = case primExpType x of
                                          IntType t -> CmpSle $ t `min` primExpIntType y
                                          FloatType t -> FCmpLe t
                                          _ -> CmpLle
x .==. y = constFoldPrimExp $
           CmpOpExp (CmpEq $ primExpType x `min` primExpType y) x y
x .>. y = y .<. x
x .>=. y = y .<=. x

-- | Lifted bitwise operators.
(.&.), (.|.), (.^.) :: PrimExp v -> PrimExp v -> PrimExp v
x .&. y = constFoldPrimExp $
          BinOpExp (And $ primExpIntType x `min` primExpIntType y) x y
x .|. y = constFoldPrimExp $
          BinOpExp (Or $ primExpIntType x `min` primExpIntType y) x y
x .^. y = constFoldPrimExp $
          BinOpExp (Xor $ primExpIntType x `min` primExpIntType y) x y

infix 4 .==., .<., .>., .<=., .>=.
infixr 3 .&&.
infixr 2 .||.

-- | Smart constructor for sign extension that does a bit of constant
-- folding.
sExt :: IntType -> PrimExp v -> PrimExp v
sExt it (ValueExp (IntValue v)) = ValueExp $ IntValue $ doSExt v it
sExt it e
  | primExpIntType e == it = e
  | otherwise = ConvOpExp (SExt (primExpIntType e) it) e

-- | Smart constructor for zero extension that does a bit of constant
-- folding.
zExt :: IntType -> PrimExp v -> PrimExp v
zExt it (ValueExp (IntValue v)) = ValueExp $ IntValue $ doZExt v it
zExt it e
  | primExpIntType e == it = e
  | otherwise = ConvOpExp (ZExt (primExpIntType e) it) e

asIntOp :: (IntType -> BinOp) -> PrimExp v -> PrimExp v -> Maybe (PrimExp v)
asIntOp f x y
  -- If either of the operands is a constant, then we prefer the type
  -- of the other operand.  This lets us use literals via fromInteger
  -- without imposing a specific type.
  | ValueExp{} <- x,
    IntType y_t <- primExpType y,
    Just x' <- asIntExp y_t x = Just $ BinOpExp (f y_t) x' y
  | ValueExp{} <- y,
    IntType x_t <- primExpType x,
    Just y' <- asIntExp x_t y = Just $ BinOpExp (f x_t) x y'

  -- Otherwise prefer the type of the leftmost operand.
  | IntType t <- primExpType x,
    Just y' <- asIntExp t y = Just $ BinOpExp (f t) x y'
  | IntType t <- primExpType y,
    Just x' <- asIntExp t x = Just $ BinOpExp (f t) x' y

  | otherwise = Nothing

asIntExp :: IntType -> PrimExp v -> Maybe (PrimExp v)
asIntExp t e
  | primExpType e == IntType t = Just e
asIntExp t (ValueExp (IntValue v)) =
  Just $ ValueExp $ IntValue $ doSExt v t
asIntExp _ _ =
  Nothing

asFloatOp :: (FloatType -> BinOp) -> PrimExp v -> PrimExp v -> Maybe (PrimExp v)
asFloatOp f x y
  | FloatType t <- primExpType x,
    Just y' <- asFloatExp t y = Just $ BinOpExp (f t) x y'
  | FloatType t <- primExpType y,
    Just x' <- asFloatExp t x = Just $ BinOpExp (f t) x' y
  | otherwise = Nothing

asFloatExp :: FloatType -> PrimExp v -> Maybe (PrimExp v)
asFloatExp t e
  | primExpType e == FloatType t = Just e
asFloatExp t (ValueExp (FloatValue v)) =
  Just $ ValueExp $ FloatValue $ doFPConv v t
asFloatExp t (ValueExp (IntValue v)) =
  Just $ ValueExp $ FloatValue $ doSIToFP v t
asFloatExp _ _ =
  Nothing

numBad :: Pretty a => String -> a -> b
numBad s x =
  error $ "Invalid argument to PrimExp method " ++ s ++ ": " ++ pretty x

-- | Evaluate a 'PrimExp' in the given monad.  Invokes 'fail' on type
-- errors.
evalPrimExp :: (Pretty v, MonadFail m) => (v -> m PrimValue) -> PrimExp v -> m PrimValue
evalPrimExp f (LeafExp v _) = f v
evalPrimExp _ (ValueExp v) = return v
evalPrimExp f (BinOpExp op x y) = do
  x' <- evalPrimExp f x
  y' <- evalPrimExp f y
  maybe (evalBad op (x,y)) return $ doBinOp op x' y'
evalPrimExp f (CmpOpExp op x y) = do
  x' <- evalPrimExp f x
  y' <- evalPrimExp f y
  maybe (evalBad op (x,y)) (return . BoolValue) $ doCmpOp op x' y'
evalPrimExp f (UnOpExp op x) = do
  x' <- evalPrimExp f x
  maybe (evalBad op x) return $ doUnOp op x'
evalPrimExp f (ConvOpExp op x) = do
  x' <- evalPrimExp f x
  maybe (evalBad op x) return $ doConvOp op x'
evalPrimExp f (FunExp h args _) = do
  args' <- mapM (evalPrimExp f) args
  maybe (evalBad h args) return $ do (_, _, fun) <- M.lookup h primFuns
                                     fun args'

evalBad :: (Pretty a, Pretty b, MonadFail m) => a -> b -> m c
evalBad op arg = fail $ "evalPrimExp: Type error when applying " ++
                 pretty op ++ " to " ++ pretty arg

-- | The type of values returned by a 'PrimExp'.  This function
-- returning does not imply that the 'PrimExp' is type-correct.
primExpType :: PrimExp v -> PrimType
primExpType (LeafExp _ t)     = t
primExpType (ValueExp v)      = primValueType v
primExpType (BinOpExp op _ _) = binOpType op
primExpType CmpOpExp{}        = Bool
primExpType (UnOpExp op _)    = unOpType op
primExpType (ConvOpExp op _)  = snd $ convOpType op
primExpType (FunExp _ _ t)    = t

-- | Is the expression a constant zero of some sort?
zeroIshExp :: PrimExp v -> Bool
zeroIshExp (ValueExp v) = zeroIsh v
zeroIshExp _            = False

-- | Is the expression a constant one of some sort?
oneIshExp :: PrimExp v -> Bool
oneIshExp (ValueExp v) = oneIsh v
oneIshExp _            = False

-- | If the given 'PrimExp' is a constant of the wrong integer type,
-- coerce it to the given integer type.  This is a workaround for an
-- issue in the 'Num' instance.
coerceIntPrimExp :: IntType -> PrimExp v -> PrimExp v
coerceIntPrimExp t (ValueExp (IntValue v)) = ValueExp $ IntValue $ doSExt v t
coerceIntPrimExp _ e                       = e

primExpIntType :: PrimExp v -> IntType
primExpIntType e = case primExpType e of IntType t -> t
                                         _         -> Int64

-- | Boolean-valued PrimExps.
true, false :: PrimExp v
true = ValueExp $ BoolValue True
false = ValueExp $ BoolValue False

-- Prettyprinting instances

instance Pretty v => Pretty (PrimExp v) where
  ppr (LeafExp v _)     = ppr v
  ppr (ValueExp v)      = ppr v
  ppr (BinOpExp op x y) = ppr op <+> parens (ppr x) <+> parens (ppr y)
  ppr (CmpOpExp op x y) = ppr op <+> parens (ppr x) <+> parens (ppr y)
  ppr (ConvOpExp op x)  = ppr op <+> parens (ppr x)
  ppr (UnOpExp op x)    = ppr op <+> parens (ppr x)
  ppr (FunExp h args _) = text h <+> parens (commasep $ map ppr args)

-- | Produce a mapping from the leaves of the 'PrimExp' to their
-- designated types.
leafExpTypes :: Ord a => PrimExp a -> S.Set (a, PrimType)
leafExpTypes (LeafExp x ptp) = S.singleton (x, ptp)
leafExpTypes (ValueExp _) = S.empty
leafExpTypes (UnOpExp _ e) = leafExpTypes e
leafExpTypes (ConvOpExp _ e) = leafExpTypes e
leafExpTypes (BinOpExp _ e1 e2) =
  S.union (leafExpTypes e1) (leafExpTypes e2)
leafExpTypes (CmpOpExp _ e1 e2) =
  S.union (leafExpTypes e1) (leafExpTypes e2)
leafExpTypes (FunExp _ pes _) =
  S.unions $ map leafExpTypes pes
