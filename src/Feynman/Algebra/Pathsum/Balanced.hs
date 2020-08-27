{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Balanced
Description : Amplitude-balanced path sums
Copyright   : (c) Matthew Amy, 2020
Maintainer  : matt.e.amy@gmail.com
Stability   : experimental
Portability : portable
-}

module Feynman.Algebra.Pathsum.Balanced where

import Data.List
import qualified Data.Set as Set
import Data.Ratio
import Data.Semigroup
import Control.Monad (mzero, msum)
import Data.Maybe (maybeToList)
import Data.Complex (Complex, mkPolar)
import Data.Bits (shiftL)
import Data.Map (Map, (!))
import qualified Data.Map as Map
import Data.String (IsString(..))

import qualified Feynman.Util.Unicode as U
import Feynman.Algebra.Base
import Feynman.Algebra.Polynomial (degree)
import Feynman.Algebra.Polynomial.Multilinear

{-----------------------------------
 Variables
 -----------------------------------}

-- | Variables are either input variables or path variables. The distinction
--   is due to the binding structure of our pathsum representation, and moreover
--   improves readability
data Var = IVar !Int | PVar !Int | FVar !String deriving (Eq, Ord)

instance Show Var where
  show (IVar i) = U.sub "x" $ fromIntegral i
  show (PVar i) = U.sub "y" $ fromIntegral i
  show (FVar x) = x

instance IsString Var where
  fromString = FVar

-- | Convenience function for the string representation of the 'i'th input variable
ivar :: Int -> String
ivar = show . IVar

-- | Convenience function for the string representation of the 'i'th path variable
pvar :: Int -> String
pvar = show . PVar

-- | Construct an integer shift for input variables
shiftI :: Int -> (Var -> Var)
shiftI i = shiftAll i 0

-- | Construct an integer shift for path variables
shiftP :: Int -> (Var -> Var)
shiftP j = shiftAll 0 j

-- | General shift. Constructs a substitution from shift values for I and P
shiftAll :: Int -> Int -> (Var -> Var)
shiftAll i j = go
  where go (IVar i') = IVar (i + i')
        go (PVar j') = PVar (j + j')

-- | Check if a variable is an input
isI :: Var -> Bool
isI (IVar _) = True
isI _        = False

-- | Check if a variable is a path variable
isP :: Var -> Bool
isP (PVar _) = True
isP _        = False

-- | Check if a variable is a free variable
isF :: Var -> Bool
isF (FVar _) = True
isF _        = False

-- | Get the string of a free variable
unF :: Var -> String
unF (FVar s) = s
unF _        = error "Not a free variable"
{-----------------------------------
 Path sums
 -----------------------------------}

-- | Path sums of the form
--   \(\frac{1}{\sqrt{2}^k}\sum_{y\in\mathbb{Z}_2^m}e^{i\pi P(x, y)}|f(x, y)\rangle\)
data Pathsum g = Pathsum {
  sde       :: !Int,
  inDeg     :: !Int,
  outDeg    :: !Int,
  pathVars  :: !Int,
  phasePoly :: !(PseudoBoolean Var g),
  outVals   :: ![SBool Var]
  } deriving (Eq)

instance (Show g, Eq g, Periodic g, Real g) => Show (Pathsum g) where
  show sop = inputstr ++ scalarstr ++ sumstr ++ amplitudestr ++ statestr
    where inputstr = case inDeg sop of
            0 -> ""
            1 -> U.ket (ivar 0) ++ " " ++ U.mapsto ++ " "
            2 -> U.ket (ivar 0) ++ U.ket (ivar 1) ++ " " ++ U.mapsto ++ " "
            j -> U.ket (ivar 0) ++ U.dots ++ U.ket (ivar (j-1)) ++ " " ++ U.mapsto ++ " "
          scalarstr = case compare (sde sop) 0 of
            LT -> U.sup ("(" ++ U.rt2 ++ ")") (fromIntegral . abs $ sde sop)
            EQ -> if (inDeg sop == 0 && outDeg sop == 0 && phasePoly sop == 0) then "1" else ""
            GT -> U.sup ("1/(" ++ U.rt2 ++ ")") (fromIntegral $ sde sop)
          sumstr = case pathVars sop of
            0 -> ""
            1 -> U.sum ++ "[" ++ pvar 0 ++ "]"
            2 -> U.sum ++ "[" ++ pvar 0 ++ pvar 1 ++ "]"
            j -> U.sum ++ "[" ++ pvar 0 ++ U.dots ++ pvar (j-1) ++ "]"
          amplitudestr = case order (phasePoly sop) of
            0 -> U.e ++ "^" ++ U.i ++ U.pi ++ "{" ++ show (phasePoly sop) ++ "}"
            1 -> ""
            2 -> "(-1)^{" ++ show (makeIntegral 1 $ phasePoly sop) ++ "}"
            4 -> U.i ++ "^{" ++ show (makeIntegral 2 $ phasePoly sop) ++ "}"
            8 -> U.omega ++ "^{" ++ show (makeIntegral 4 $ phasePoly sop) ++ "}"
            j -> U.sub U.zeta j ++ "^{" ++ show (makeIntegral j $ phasePoly sop) ++ "}"
          statestr = concatMap (U.ket . show) $ outVals sop

-- | Convenience function for pretty printing
makeIntegral :: Real g => Integer -> PseudoBoolean v g -> PseudoBoolean v Integer
makeIntegral i = cast (\a -> numerator $ toRational a * toRational i)

-- | Retrieve the internal path variables
internalPaths :: Pathsum g -> [Var]
internalPaths sop = [PVar i | i <- [0..pathVars sop - 1]] \\ outVars
  where outVars = Set.toList . Set.unions . map vars $ outVals sop

-- | Retrieve the free variables
freeVars :: Pathsum g -> [String]
freeVars sop = map unF . Set.toList . Set.filter isF . foldr (Set.union) Set.empty $ xs
  where xs = (vars $ phasePoly sop):(map vars $ outVals sop)

-- | Checks if the path sum is (trivially) the identity
isTrivial :: (Eq g, Num g) => Pathsum g -> Bool
isTrivial sop = sop == identity (inDeg sop)

{----------------------------
 Constructors
 ----------------------------}

-- | Construct an 'n'-qubit identity operator
identity :: (Eq g, Num g) => Int -> Pathsum g
identity n = Pathsum 0 n n 0 0 [ofVar (IVar i) | i <- [0..n-1]]

-- | Construct a (symbolic) state
ket :: (Eq g, Num g) => [SBool String] -> Pathsum g
ket xs = Pathsum 0 0 (fromIntegral $ length xs) 0 0 $ map (rename FVar) xs

-- | Initialize a fresh ancilla
initialize :: (Eq g, Num g) => FF2 -> Pathsum g
initialize b = ket [constant b]

{-# INLINE initialize #-}

-- | Construct a uniform superposition of classical states of a given form
superposition :: (Ord v, Eq g, Num g) => [SBool v] -> Pathsum g
superposition xs = Pathsum k 0 n k 0 $ map (rename sub) xs
  where n   = length xs
        k   = Set.size fv
        fv  = Set.unions $ map vars xs
        sub = ((Map.fromList [(v, PVar i) | (v, i) <- zip (Set.toList fv) [0..]])!)

-- | Construct a classical transformation from the free variables of 'xs' to 'xs'
--   Effectively binds the free variables in 'state xs'
compute :: (Ord v, Eq g, Num g) => [SBool v] -> Pathsum g
compute xs = Pathsum 0 (Set.size fv) (length xs) 0 0 $ map (rename sub) xs
  where fv  = Set.unions $ map vars xs
        sub = ((Map.fromList [(v, IVar i) | (v, i) <- zip (Set.toList fv) [0..]])!)

-- | Breaks the connection between inputs and outputs by mapping
--   any input basis state to the maximally mixed state. Non-unitary
disconnect :: (Eq g, Num g) => Int -> Pathsum g
disconnect n = Pathsum n n n n 0 [ofVar $ PVar i | i <- [0..n-1]]

-- | Extend a path sum by adding a given number of qubits with the specified
--   input and output embedding
extend :: Pathsum g -> Int -> (Int -> Int) -> Pathsum g
extend (Pathsum a b c d e f) n embed
  | n < 0  = error "Cannot embed path sum in smaller space!"
  | b /= c = error "Can only extend square path sums"
  | otherwise      = Pathsum a (b+n) (c+n) d (rename sub e) output
    where sub x   = case x of
            (IVar i) -> IVar (embed i)
            _        -> x
          output  = [Map.findWithDefault (ofVar $ IVar i) i initial | i <- [0..c+n-1]]
          initial =
            let go (v, i) = Map.insert (embed i) (rename sub v) in
              foldr go Map.empty $ zip f [0..]

{----------------------------
 Dual constructors
 ----------------------------}

-- | Construct a (symbolic) state destructor
bra :: (Eq g, Abelian g) => [SBool String] -> Pathsum g
bra xs = Pathsum (2*m) m 0 m (lift $ p) []
  where m         = fromIntegral $ length xs
        p         = foldr (+) 0 . map go $ zip [0..] xs
        go (i, v) = ofVar (PVar i) * (ofVar (IVar i) + (rename fromString v))

-- | Alternate state destructor with fewer paths but a more complicated polynomial
unstateAlt :: (Eq g, Abelian g) => [SBool String] -> Pathsum g
unstateAlt xs = Pathsum 2 (fromIntegral $ length xs) 0 1 (lift $ y*(1 + p)) []
  where y = ofVar (PVar 0)
        p = foldr (*) 1 . map valF $ zip xs [0..]
        valF (val, i) = 1 + (rename fromString val) + ofVar (IVar i)

-- | Dagger of initialize -- i.e. unnormalized post-selection
postselect :: (Eq g, Abelian g) => FF2 -> Pathsum g
postselect b = bra [constant b]

{-# INLINE postselect #-}

-- | Select on a classical state of a given form
unsuper :: (Ord v, Eq g, Abelian g) => [SBool v] -> Pathsum g
unsuper xs = Pathsum (2*m + n) m 0 (m+n) poly []
  where m    = length xs
        n    = Set.size fv
        fv   = Set.unions $ map vars xs
        sub  = ((Map.fromList [(v, PVar (m + i)) | (v, i) <- zip (Set.toList fv) [0..]])!)
        poly = foldr (+) zero $ map constructTerm [0..m-1]
        constructTerm i = lift $ ofVar (PVar i) * (ofVar (IVar i) + rename sub (xs!!i))

-- | Invert a classical transformation
uncompute :: (Ord v, Eq g, Abelian g) => [SBool v] -> Pathsum g
uncompute xs = Pathsum (2*m) m n (m+n) poly [ofVar (PVar $ m + i) | i <- [0..n-1]]
  where m    = length xs
        n    = Set.size fv
        fv   = Set.unions $ map vars xs
        sub  = ((Map.fromList [(v, PVar (m + i)) | (v, i) <- zip (Set.toList fv) [0..]])!)
        poly = foldr (+) zero $ map constructTerm [0..m-1]
        constructTerm i = lift $ ofVar (PVar i) * (ofVar (IVar i) + rename sub (xs!!i))

{----------------------------
 Constants & gates
 ----------------------------}

-- | \(\sqrt{2}\)
root2 :: (Eq g, Abelian g, Dyadic g) => Pathsum g
root2 = Pathsum 0 0 0 1 ((-constant (half * half)) - scale half (lift $ ofVar (PVar 0))) []

-- | \(i\)
iunit :: (Eq g, Abelian g, Dyadic g) => Pathsum g
iunit = Pathsum 0 0 0 0 (constant half) []

-- | \(e^{i\pi/4}\)
omega :: (Eq g, Abelian g, Dyadic g) => Pathsum g
omega = Pathsum 0 0 0 0 (constant (half * half)) []

-- | A fresh, 0-valued ancilla
fresh :: (Eq g, Num g) => Pathsum g
fresh = Pathsum 0 0 1 0 0 [0]

-- | X gate
xgate :: (Eq g, Num g) => Pathsum g
xgate = Pathsum 0 1 1 0 0 [1 + ofVar (IVar 0)]

-- | Z gate
zgate :: (Eq g, Abelian g) => Pathsum g
zgate = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = lift $ ofVar (IVar 0)

-- | Y gate
ygate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
ygate = Pathsum 0 1 1 0 p [1 + ofVar (IVar 0)]
  where p = constant half + (lift $ ofVar (IVar 0))

-- | S gate
sgate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
sgate = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = scale half (lift $ ofVar (IVar 0))

-- | S* gate
sdggate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
sdggate = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = scale (3*half) (lift $ ofVar (IVar 0))

-- | T gate
tgate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
tgate = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = scale (half*half) (lift $ ofVar (IVar 0))

-- | T* gate
tdggate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
tdggate = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = scale (7*half*half) (lift $ ofVar (IVar 0))

-- | R_k gate
rkgate :: (Eq g, Abelian g, Dyadic g) => Int -> Pathsum g
rkgate k = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = scale (fromDyadic $ dyadic 1 k) (lift $ ofVar (IVar 0))

-- | R_z gate
rzgate :: (Eq g, Abelian g, Dyadic g) => DyadicRational -> Pathsum g
rzgate theta = Pathsum 0 1 1 0 p [ofVar (IVar 0)]
  where p = scale (fromDyadic theta) (lift $ ofVar (IVar 0))

-- | H gate
hgate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
hgate = Pathsum 1 1 1 1 p [ofVar (PVar 0)]
  where p = lift $ (ofVar $ IVar 0) * (ofVar $ PVar 0)

-- | CH gate
chgate :: (Eq g, Abelian g, Dyadic g) => Pathsum g
chgate = Pathsum 1 2 2 1 p [x1, x2 + x1*x2 + x1*y]
  where p = lift $ x1 * x2 * y
        x1 = ofVar $ IVar 0
        x2 = ofVar $ IVar 1
        y = ofVar $ PVar 0

-- | CNOT gate
cxgate :: (Eq g, Num g) => Pathsum g
cxgate = Pathsum 0 2 2 0 0 [x0, x0+x1]
  where x0 = ofVar $ IVar 0
        x1 = ofVar $ IVar 1

-- | Toffoli gate
ccxgate :: (Eq g, Num g) => Pathsum g
ccxgate = Pathsum 0 3 3 0 0 [x0, x1, x2 + x0*x1]
  where x0 = ofVar $ IVar 0
        x1 = ofVar $ IVar 1
        x2 = ofVar $ IVar 2

-- | SWAP gate
swapgate :: (Eq g, Num g) => Pathsum g
swapgate = Pathsum 0 2 2 0 0 [x1, x0]
  where x0 = ofVar $ IVar 0
        x1 = ofVar $ IVar 1

{----------------------------
 Bind and unbind
 ----------------------------}

-- | Bind some collection of free variables in a path sum
bind :: (Foldable f, Eq g, Abelian g) => f String -> Pathsum g -> Pathsum g
bind = flip (foldr go)
  where go x sop =
          let v = IVar $ inDeg sop in
            sop { inDeg = (inDeg sop) + 1,
                  phasePoly = subst (FVar x) (ofVar v) (phasePoly sop),
                  outVals = map (subst (FVar x) (ofVar v)) (outVals sop) }

-- | Close a path sum by binding all free variables
close :: (Eq g, Abelian g) => Pathsum g -> Pathsum g
close sop = bind (freeVars sop) sop

-- | Unbind (instantiate) some collection of inputs
{-
unbind :: Foldable f => f Int -> Pathsum g -> Pathsum g
unbind = flip (foldr go)
  where go i (Pathsum a b c d e f)
          | i >= b || i < 0 = error "Can't unbind " ++ show i ++ "th variable"
          | otherwise       =
            let inst = "#" ++ show (IVar i)
                sub (IVar j)
                  | j == i   = ofVar $ FVar inst
                  | j > i     = ofVar $ IVar (j-1)
                  | otherwise = IVar j
            in
              sop { inDeg = b - 1,
                    phasePoly = substMany sub e,
                    outVals = map (substMany sub) f }

-- | Open a path sum by binding all free variables
close :: Pathsum g -> Pathsum g
close sop = bind (freeVars sop)
-}
{----------------------------
 Operators
 ----------------------------}

-- | Take the dagger of a path sum
--dagger :: Pathsum g -> Pathsum g
--dagger (Pathsum a b c d e f) = Pathsum ? c b ? ? ?

-- | Attempt to add two path sums. Only succeeds if the resulting sum is balanced
--   and the dimensions match.
plusMaybe :: (Eq g, Abelian g) => Pathsum g -> Pathsum g -> Maybe (Pathsum g)
plusMaybe sop sop'
  | inDeg sop  /= inDeg sop'                                       = Nothing
  | outDeg sop /= outDeg sop'                                      = Nothing
  | (sde sop) + 2*(pathVars sop') /= (sde sop') + 2*(pathVars sop) = Nothing
  | otherwise = Just $ Pathsum sde' inDeg' outDeg' pathVars' phasePoly' outVals'
  where sde'       = (sde sop) + 2*(pathVars sop')
        inDeg'     = inDeg sop
        outDeg'    = outDeg sop
        pathVars'  = (pathVars sop) + (pathVars sop') + 1
        y          = ofVar $ PVar (pathVars' - 1)
        phasePoly' = (lift y)*(phasePoly sop) +
                     (lift (1+y))*(renameMonotonic shift $ phasePoly sop')
        outVals'   = map (\(a,b) -> b + y*(a + b)) $
                       zip (outVals sop) (map (renameMonotonic shift) $ outVals sop')
        shift x    = case x of
          PVar i -> PVar $ i + (pathVars sop)
          _      -> x

-- | Construct the sum of two path sums. Raises an error if the sums are incompatible
plus :: (Eq g, Abelian g) => Pathsum g -> Pathsum g -> Pathsum g
plus sop sop' = case plusMaybe sop sop' of
  Nothing    -> error "Incompatible path sums"
  Just sop'' -> sop''

-- | Compose two path sums in parallel
tensor :: (Eq g, Num g) => Pathsum g -> Pathsum g -> Pathsum g
tensor sop sop' = Pathsum sde' inDeg' outDeg' pathVars' phasePoly' outVals'
  where sde'       = (sde sop) + (sde sop')
        inDeg'     = (inDeg sop) + (inDeg sop')
        outDeg'    = (outDeg sop) + (outDeg sop')
        pathVars'  = (pathVars sop) + (pathVars sop')
        phasePoly' = (phasePoly sop) + (renameMonotonic shift $ phasePoly sop')
        outVals'   = (outVals sop) ++ (map (renameMonotonic shift) $ outVals sop')
        shift x    = case x of
          IVar i -> IVar $ i + (inDeg sop)
          PVar i -> PVar $ i + (pathVars sop)

-- | Attempt to compose two path sums in sequence. Only succeeds if the dimensions
--   are compatible (i.e. if the out degree of the former is the in degree of the
--   latter)
timesMaybe :: (Eq g, Abelian g) => Pathsum g -> Pathsum g -> Maybe (Pathsum g)
timesMaybe sop sop'
  | outDeg sop /= inDeg sop' = Nothing
  | otherwise = Just $ Pathsum sde' inDeg' outDeg' pathVars' phasePoly' outVals'
  where sde'       = (sde sop) + (sde sop')
        inDeg'     = inDeg sop
        outDeg'    = outDeg sop'
        pathVars'  = (pathVars sop) + (pathVars sop')
        phasePoly' = (phasePoly sop) +
                     (substMany sub . renameMonotonic shift $ phasePoly sop')
        outVals'   = (map (substMany sub . renameMonotonic shift) $ outVals sop')
        shift x    = case x of
          PVar i -> PVar $ i + (pathVars sop)
          _      -> x
        sub x      = case x of
          IVar i -> (outVals sop)!!i
          _      -> ofVar x

-- | Compose two path sums in sequence. Throws an error if the dimensions are
--   not compatible
times :: (Eq g, Abelian g) => Pathsum g -> Pathsum g -> Pathsum g
times sop sop' = case timesMaybe sop sop' of
  Nothing    -> error "Incompatible path sum dimensions"
  Just sop'' -> sop''

-- | Left-to-right composition
(.>) :: (Eq g, Abelian g) => Pathsum g -> Pathsum g -> Pathsum g
(.>) = times

infixr 5 .>

-- | Scale the normalization factor
renormalize :: Int -> Pathsum g -> Pathsum g
renormalize k (Pathsum a b c d e f) = Pathsum (a + k) b c d e f

{--------------------------
 Type class instances
 --------------------------}
  
instance (Eq g, Num g) => Semigroup (Pathsum g) where
  (<>) = tensor

instance (Eq g, Num g) => Monoid (Pathsum g) where
  mempty  = Pathsum 0 0 0 0 0 []
  mappend = tensor

instance (Eq g, Abelian g) => Num (Pathsum g) where
  (+)                          = plus
  (*)                          = (flip times)
  negate (Pathsum a b c d e f) = Pathsum a b c d (lift 1 + e) f
  abs (Pathsum a b c d e f)    = Pathsum a b c d (dropConstant e) f
  signum sop                   = sop
  fromInteger                  = identity . fromInteger

instance Functor Pathsum where
  fmap g (Pathsum a b c d e f) = Pathsum a b c d (cast g e) f

{--------------------------
 Reduction rules
 --------------------------}

{-
class RewriteRule rule g where
  matchAll :: Pathsum g -> [rule]
  matchOne :: Pathsum g -> rule
  apply :: rule -> Pathsum g -> Pathsum g

data E = E !Var {-# UNBOX #-}

instance (Eq g, Periodic g) => RewriteRule E g where
  match = matchElim
  apply = applyElim
-}

-- | Maps the order 1 and order 2 elements of a group to FF2
injectFF2 :: Periodic g => g -> Maybe FF2
injectFF2 a = case order a of
  1 -> Just 0
  2 -> Just 1
  _ -> Nothing

-- | Gives a Boolean polynomial equivalent to the current polynomial, if possible
toBooleanPoly :: (Eq g, Periodic g) => PseudoBoolean v g -> Maybe (SBool v)
toBooleanPoly = castMaybe injectFF2

-- | Elim rule. \(\dots(\sum_y)\dots = \dots 2 \dots\)
matchElim :: (Eq g, Periodic g) => Pathsum g -> [Var]
matchElim sop = msum . (map go) $ internalPaths sop
  where go v = if Set.member v (vars $ phasePoly sop) then [] else [v]

-- | Generic HH rule. \(\dots(\sum_y (-1)^{y\cdot f})\dots = \dots|_{f = 0}\)
matchHH :: (Eq g, Periodic g) => Pathsum g -> [(Var, SBool Var)]
matchHH sop = msum . (map (maybeToList . go)) $ internalPaths sop
  where go v = toBooleanPoly (quotVar v $ phasePoly sop) >>= \p -> return (v, p)

-- | Solvable instances of the HH rule.
--   \(\dots(\sum_y (-1)^{y(z \oplus f)})\dots = \dots[z \gets f]\)
matchHHSolve :: (Eq g, Periodic g) => Pathsum g -> [(Var, Var, SBool Var)]
matchHHSolve sop = do
  (v, p)   <- matchHH sop
  (v', p') <- solveForX p
  case v' of
    PVar _ -> return (v, v', p')
    _      -> mzero

-- | Instances of the HH rule with a linear substitution
matchHHLinear :: (Eq g, Periodic g) => Pathsum g -> [(Var, Var, SBool Var)]
matchHHLinear sop = do
  (v, p)   <- filter (\(_, p) -> degree p <= 1) $ matchHH sop
  (v', p') <- solveForX p
  return (v, v', p')

-- | Instances of the (\omega\) rule
matchOmega :: (Eq g, Periodic g, Dyadic g) => Pathsum g -> [(Var, SBool Var)]
matchOmega sop = do
  v <- internalPaths sop
  p <- maybeToList . toBooleanPoly . addFactor v $ phasePoly sop
  return (v, p)
  where addFactor v p = constant (fromDyadic $ dyadic 1 1) + quotVar v p

{--------------------------
 Pattern synonyms
 --------------------------}

-- | Pattern synonym for Elim
pattern Triv :: (Eq g, Num g) => Pathsum g
pattern Triv <- (isTrivial -> True)

-- | Pattern synonym for Elim
pattern Elim :: (Eq g, Periodic g) => Var -> Pathsum g
pattern Elim v <- (matchElim -> (v:_))

-- | Pattern synonym for HH
pattern HH :: (Eq g, Periodic g) => Var -> SBool Var -> Pathsum g
pattern HH v p <- (matchHH -> (v, p):_)

-- | Pattern synonym for solvable HH instances
pattern HHSolved :: (Eq g, Periodic g) => Var -> Var -> SBool Var -> Pathsum g
pattern HHSolved v v' p <- (matchHHSolve -> (v, v', p):_)

-- | Pattern synonym for linear HH instances
pattern HHLinear :: (Eq g, Periodic g) => Var -> Var -> SBool Var -> Pathsum g
pattern HHLinear v v' p <- (matchHHLinear -> (v, v', p):_)

-- | Pattern synonym for HH instances where the polynomial is strictly a
--   function of input variables
pattern HHKill :: (Eq g, Periodic g) => Var -> SBool Var -> Pathsum g
pattern HHKill v p <- (filter (all (not . isP) . vars . snd) . matchHH -> (v, p):_)

-- | Pattern synonym for Omega instances
pattern Omega :: (Eq g, Periodic g, Dyadic g) => Var -> SBool Var -> Pathsum g
pattern Omega v p <- (matchOmega -> (v, p):_)

{--------------------------
 Applying reductions
 --------------------------}

-- | Apply an elim rule. Does not check if the instance is valid
applyElim :: Var -> Pathsum g -> Pathsum g
applyElim (PVar i) (Pathsum a b c d e f) = Pathsum (a-2) b c (d-1) e' f'
  where e' = renameMonotonic varShift e
        f' = map (renameMonotonic varShift) f
        varShift (PVar j)
          | j > i     = PVar $ j - 1
          | otherwise = PVar $ j
        varShift v = v

-- | Apply a (solvable) HH rule. Does not check if the instance is valid
applyHHSolved :: (Eq g, Abelian g) => Var -> Var -> SBool Var -> Pathsum g -> Pathsum g
applyHHSolved (PVar i) v p (Pathsum a b c d e f) = Pathsum a b c (d-1) e' f'
  where e' = renameMonotonic varShift . subst v p . remVar (PVar i) $ e
        f' = map (renameMonotonic varShift . subst v p) f
        varShift (PVar j)
          | j > i     = PVar $ j - 1
          | otherwise = PVar $ j
        varShift v = v

-- | Apply an (\omega\) rule. Does not check if the instance is valid
applyOmega :: (Eq g, Abelian g, Dyadic g) => Var -> SBool Var -> Pathsum g -> Pathsum g
applyOmega (PVar i) p (Pathsum a b c d e f) = Pathsum (a-1) b c (d-1) e' f'
  where e' = renameMonotonic varShift $ p' + remVar (PVar i) e
        f' = map (renameMonotonic varShift) f
        p' = constant (fromDyadic $ dyadic 1 2) + scale (fromDyadic $ dyadic 3 1) (lift p)
        varShift (PVar j)
          | j > i     = PVar $ j - 1
          | otherwise = PVar $ j
        varShift v = v

-- | Finds and applies the first elimination instance
rewriteElim :: (Eq g, Periodic g) => Pathsum g -> Pathsum g
rewriteElim sop = case sop of
  Elim v -> applyElim v sop
  _      -> sop

-- | Finds and applies the first hh instance
rewriteHH :: (Eq g, Periodic g) => Pathsum g -> Pathsum g
rewriteHH sop = case sop of
  HHSolved v v' p -> applyHHSolved v v' p sop
  _               -> sop

-- | Finds and applies the first omega instance
rewriteOmega :: (Eq g, Periodic g, Dyadic g) => Pathsum g -> Pathsum g
rewriteOmega sop = case sop of
  Omega v p -> applyOmega v p sop
  _         -> sop

{--------------------------
 Reduction procedures
 --------------------------}

-- | Performs basic simplifications
simplify :: (Eq g, Periodic g, Dyadic g) => Pathsum g -> Pathsum g
simplify sop = case sop of
  Elim y         -> grind $ applyElim y sop
  HHLinear y z p -> grind $ applyHHSolved y z p sop
  Omega y p      -> grind $ applyOmega y p sop
  _              -> sop

-- | A complete normalization procedure for Clifford circuits. Originally described in
--   the paper M. Amy,
--   / Towards Large-Scaled Functional Verification of Universal Quantum Circuits /, QPL 2018.
grind :: (Eq g, Periodic g, Dyadic g) => Pathsum g -> Pathsum g
grind sop = case sop of
  Elim y         -> grind $ applyElim y sop
  HHSolved y z p -> grind $ applyHHSolved y z p sop
  Omega y p      -> grind $ applyOmega y p sop
  _              -> sop

-- | A single step of 'grind'
grindStep :: (Eq g, Periodic g, Dyadic g) => Pathsum g -> Pathsum g
grindStep sop = case sop of
  Elim y         -> applyElim y sop
  HHSolved y z p -> applyHHSolved y z p sop
  Omega y p      -> applyOmega y p sop
  _              -> sop

{--------------------------
 Simulation
 --------------------------}

-- | Simulates a pathsum on a given input
simulate :: (Eq g, Periodic g, Dyadic g, Real g, RealFloat f) =>
            Pathsum g -> [FF2] -> Map [FF2] (Complex f)
simulate sop xs = go $ sop * ket (map constant xs)
  where go      = go' . grind
        go' ps  = case ps of
          (Pathsum k 0 _ 0 p xs) ->
            let phase     = fromRational . toRational $ getConstant p
                base      = case k `mod` 2 of
                  0 -> fromInteger $ 1 `shiftL` (abs k)
                  1 -> sqrt(2.0) * (fromInteger $ 1 `shiftL` (abs (k-1)))
                magnitude = base**(fromIntegral $ signum k)
            in
              Map.singleton (map getConstant xs) (mkPolar magnitude (pi * phase))
          (Pathsum k 0 n i p xs) ->
            let v     = PVar $ i-1
                left  = go (Pathsum k 0 n (i-1) (subst v zero p) (map (subst v zero) xs))
                right = go (Pathsum k 0 n (i-1) (subst v one p) (map (subst v one) xs))
            in
              Map.unionWith (+) left right
          _                      -> error "Incompatible dimensions"

-- | Evaluates a pathsum on a given input and output
amplitude :: (Eq g, Periodic g, Dyadic g, Real g, RealFloat f) =>
             [FF2] -> Pathsum g -> [FF2] -> Complex f
amplitude o sop i = (simulate (bra (map constant o) * sop) i)![]