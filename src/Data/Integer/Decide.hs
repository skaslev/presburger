{-# LANGUAGE CPP #-}
{-# LANGUAGE Safe, PatternGuards, BangPatterns #-}
{-|
This module implements a decision procedure for quantifier-free linear
arithmetic.  The algorithm is based on the following paper:

  An Online Proof-Producing Decision Procedure for
  Mixed-Integer Linear Arithmetic
  by
  Sergey Berezin, Vijay Ganesh, and David L. Dill
-}
module Data.Integer.Decide
  ( -- * Solver states
    PropSet
  , emptyPropSet
  , ppPropSet

  , Prop
  , (|=|)
  , (|<|)
  , ppProp
  , assertProp
  , getModel

  -- * Provenance
  , Provenance
  , basicAssert
  , provenance
  , ppProvenance

  -- * Terms
  , Term
  , tVar
  , tConst
  , (|+|)
  , (|-|)
  , (|*|)
  , tNeg
  , tLet
  , tLetNum
  , tLetNums
  , ppTerm

  -- * Names
  , Name
  , toName
  , fromName
  , ppName
  ) where

import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.List(partition)
import           Data.Maybe(maybeToList,fromMaybe)
import           Control.Monad(liftM,ap,forM_,mplus,guard)
import           Text.PrettyPrint
import           Data.Set ( Set )
import qualified Data.Set as Set

#if __GLASGOW_HASKELL__ < 710
import           Control.Applicative(Applicative(..), (<$>))
#endif


--------------------------------------------------------------------------------

infix 4 |=|, |<|

(|=|) :: Term -> Term -> Prop
x |=| y = PEq0 (ctEq x y)

(|<|) :: Term -> Term -> Prop
x |<| y = PLt0 (ctLt x y)

--------------------------------------------------------------------------------

-- | The current solver state. The type parameter is used to name the
-- propsitions that are currently asserted.
newtype PropSet lit = PropSet (RW lit)


-- | A proposition.
data Prop       = PEq0 Term | PLt0 Term

instance Show Prop where
  showsPrec c p = showsPrec c (show (ppProp p))

-- | Pretty print a proposition.
ppProp :: Prop -> Doc
ppProp prop =
  case prop of
    PEq0 t  -> ppTerm t <+> text "="  <+> text "0"
    PLt0 t  -> ppTerm t <+> text "<"  <+> text "0"

-- | Pretty print the current solver state.
ppPropSet :: PropSet lit -> Doc
ppPropSet (PropSet rw) = ppInerts (inerts rw)

-- | An empty set of assertions.
emptyPropSet :: PropSet lit
emptyPropSet = PropSet initRW

{- | Assert a proposition.

    * If we detect a contradiction, then we report the reason on the left.
    * Otherwise, we get a new proposet, and a conjunction of disjunctions
      of new proposition.

The propoerty is satisfiable as long as one of these sub-goals is
compatible with the new state.
-}
assertProp :: Ord lit =>
  (Provenance lit, Prop) ->
  PropSet lit ->
  Either (Provenance lit)
         (PropSet lit, [[(Provenance lit, Prop)]])
assertProp (proof,prop) (PropSet rw) =
  case prop of
    PEq0 t  -> go (solveIs0   (proof, t))
    PLt0 t  -> go (solveIsNeg (proof, t))
  where
  go m =
    case runS m rw of
      Error e -> Left e
      Ok _ rw1 ->
        let mk f (p,t) = (p, f t)
            cvt c =      mk PLt0  (darkShadow c)
                  : map (mk PEq0) (grayShadow c)
        in Right (PropSet rw1 { delayed = [] }, map cvt (delayed rw1))


getModel :: PropSet lit -> [(Name,Integer)]
getModel (PropSet rw) = iModel (inerts rw)

--------------------------------------------------------------------------------
-- Constraints and Bounds on Variables

ctLt :: Term -> Term -> Term
ctLt t1 t2 = t1 |-| t2

ctEq :: Term -> Term -> Term
ctEq t1 t2 = t1 |-| t2

data Bound lit  = Bound (Provenance lit) Integer Term
                  -- ^ The integer is strictly positive
                  deriving Show

data BoundType  = Lower | Upper
                  deriving Show

toCt :: BoundType -> Name -> Bound lit -> (Provenance lit, Term)
toCt Lower x (Bound p c t) = (p, ctLt t              (c |*| tVar x))
toCt Upper x (Bound p c t) = (p, ctLt (c |*| tVar x) t)



--------------------------------------------------------------------------------
-- Inert set


-- | The inert contains the solver state on one possible path.
data Inerts a = Inerts
  { bounds :: Map Name ([Bound a],[Bound a])
    {- ^ Known lower and upper bounds for variables.
          * Each bound @(c,t)@ in the first list asserts that  @t < c * x@
          * Each bound @(c,t)@ in the second list asserts that @c * x < t@
          * Invariant: the bounds on variable `x` depend only on variables
                       larger than `x`.  Thus, the largest variable has
                       only an integer bound, the next smaller one may depend
                       on the largest one, etc. -}

  , solved :: Map Name (Provenance a, Term)
    {- ^ Definitions for resolved variables.
    These form an idempotent substitution.
    The provenance keeps track of how each equation came to be. -}
  } deriving Show

ppInerts :: Inerts a -> Doc
ppInerts is = vcat $ [ ppLower x b | (x,(ls,_)) <- bnds, b <- ls ] ++
                     [ ppUpper x b | (x,(_,us)) <- bnds, b <- us ] ++
                     [ ppEq e      | e <- Map.toList (solved is) ]
  where
  bnds = Map.toList (bounds is)

  ppT c x                 = ppTerm (c |*| tVar x)
  ppLower x (Bound _ c t) = ppTerm t <+> text "<" <+> ppT c x
  ppUpper x (Bound _ c t) = ppT c x  <+> text "<" <+> ppTerm t
  ppEq (x,(_,t))          = ppName x <+> text "=" <+> ppTerm t



-- | An empty inert set.
iNone :: Inerts a
iNone = Inerts { bounds = Map.empty
               , solved = Map.empty
               }

-- | Rewrite a term using the definitions from an inert set.
iApSubst :: Ord a => Inerts a -> (Provenance a,Term) -> (Provenance a,Term)
iApSubst i t = foldr apS t $ Map.toList $ solved i
  where apS (x,(p1,t1)) (p2,t2) = case tLet' x t1 t2 of
                                    Nothing  -> (p2,t2)
                                    Just t2' -> (usesBoth p1 p2, t2')

{- | Add a definition.  Upper and lower bound constraints that mention
the variable are "kicked-out" so that they can be reinserted in the
context of the new knowledge.

  * Assumes the substitution has already been applied.

  * The kicked-out constraints are NOT rewritten, this happens
    when they get inserted in the work queue.

The kick-out bit seems necessary to preserve the invariants on the inerts.
For example, consider a constraint like this:

  p < 5 * a

Now, suppose that we've discovered that `a = z`.  We can't just substitute,
because the result, `p < 5 * z` would violate the invariant that `p` can
only depend on smaller variables.  Instead, we'd have to rewrite the constraints
so that `z` is constrained by `p`.
-}

iSolved :: Ord a => Provenance a -> Name -> Term -> Inerts a ->
                                            ([(Provenance a,Term)], Inerts a)
iSolved proof x t i =
  ( kickedOut
  , Inerts { bounds = otherBounds
           , solved = Map.insert x (proof,t)
                    $ Map.map updExisting
                    $ solved i
           }
  )
  where
  updExisting it@(prov,t1) = case tLet' x t t1 of
                               Nothing -> it
                               Just t2 -> (usesBoth proof prov, t2)

  (kickedOut, otherBounds) =

        -- First, we eliminate the bounds on `x` (i.e., `x` is in the key)
    let (mb, mp1) = Map.updateLookupWithKey (\_ _ -> Nothing) x (bounds i)

        -- Next, we elminate all constraints that mentiond `x` in the bounds
        -- (i.e., `x` is in the values)
        mp2 = Map.mapWithKey extractBounds mp1

    in ( [ ct | (lbs,ubs) <- maybeToList mb
              ,  ct <- map (toCt Lower x) lbs ++ map (toCt Upper x) ubs ]
         ++
         [ ct | (_,cts) <- Map.elems mp2, ct <- cts ]

       , fmap fst mp2
       )

  -- Splits up the values of a map into two parts:
  --    * the first is the set of constraints that remains
  --    * the second is the set of constraints that are kicked-out.
  extractBounds y (lbs,ubs) =
    let (lbsStay, lbsKick) = partition stay lbs
        (ubsStay, ubsKick) = partition stay ubs
    in ( (lbsStay,ubsStay)
       , map (toCt Lower y) lbsKick ++
         map (toCt Upper y) ubsKick
       )

  stay (Bound _ _ bnd) = not (tHasVar x bnd)


iModel :: Inerts a -> [(Name,Integer)]
iModel i = goBounds [] (bounds i)
  where
  goBounds su mp =
    case Map.maxViewWithKey mp of
      Nothing -> goEqs su $ Map.toList $ solved i
      Just ((x,(lbs0,ubs0)), mp1) ->
        let lbs = [ Bound p c (tLetNums su t) | Bound p c t <- lbs0 ]
            ubs = [ Bound p c (tLetNums su t) | Bound p c t <- ubs0 ]
            sln = fromMaybe 0
                $ mplus (iPickBounded Lower lbs) (iPickBounded Upper ubs)
        in goBounds ((x,sln) : su) mp1

  goEqs su [] = su
  goEqs su ((x,(_,t)) : more) =
    let t1  = tLetNums su t
        vs  = tVarList t1
        su1 = [ (v,0) | v <- vs ] ++ (x,tConstPart t1) : su
    in goEqs su1 more


-- Given a list of lower (resp. upper) bounds, compute the least (resp. largest)
-- value that satisfies them all.
iPickBounded :: BoundType -> [Bound a] -> Maybe Integer
iPickBounded _ [] = Nothing
iPickBounded bt bs =
  do xs <- mapM (normBound bt) bs
     return $ case bt of
                Lower -> maximum xs
                Upper -> minimum xs
  where
  -- t < c*x
  -- <=> t+1 <= c*x
  -- <=> (t+1)/c <= x
  -- <=> ceil((t+1)/c) <= x
  -- <=> t `div` c + 1 <= x
  normBound Lower (Bound _ c t) = do k <- isConst t
                                     return (k `div` c + 1)
  -- c*x < t
  -- <=> c*x <= t-1
  -- <=> x   <= (t-1)/c
  -- <=> x   <= floor((t-1)/c)
  -- <=> x   <= (t-1) `div` c
  normBound Upper (Bound _ c t) = do k <- isConst t
                                     return (div (k-1) c)




--------------------------------------------------------------------------------
-- Solving constraints

solveIs0 :: Ord a => (Provenance a, Term) -> S a ()
solveIs0 t = solveIs0' =<< apSubst t

-- | Solve a constraint if the form @t = 0@.
-- Assumes substitution has already been applied.
solveIs0' :: Ord a => (Provenance a, Term) -> S a ()
solveIs0' (proof,t)

  -- A == 0
  | Just a <- isConst t = guarded proof (a == 0)

  -- A + B * x = 0
  | Just (a,b,x) <- tIsOneVar t =
    case divMod (-a) b of
      (q,0) -> addDef proof x (tConst q)
      _     -> failure proof

  --  x + S = 0
  -- -x + S = 0
  | Just (xc,x,s) <- tGetSimpleCoeff t =
    addDef proof x (if xc > 0 then tNeg s else s)

  -- A * S = 0
  -- This does not mess with new variables, so we don't need
  -- to re-apply the substitution.
  | Just (_, s) <- tFactor t  = solveIs0' (proof,s)

  -- See Section 3.1 of paper for details.
  -- We obtain an equivalent formulation but with smaller coefficients.
  | Just (ak,xk,s) <- tLeastAbsCoeff t =
      do let m = abs ak + 1
         v <- newVar
         let sgn  = signum ak
             soln =     (negate sgn * m) |*| tVar v
                    |+| tMapCoeff (\c -> sgn * modulus c m) s
         addDef proof xk soln

         let upd i = div (2*i + m) (2*m) + modulus i m
         solveIs0 (proof, negate (abs ak) |*| tVar v |+| tMapCoeff upd s)

  | otherwise = error "solveIs0: unreachable"

modulus :: Integer -> Integer -> Integer
modulus a m = a - m * div (2 * a + m) (2 * m)


solveIsNeg :: Ord a => (Provenance a,Term) -> S a ()
solveIsNeg t = solveIsNeg' =<< apSubst t

-- | Solve a constraint of the form @t < 0@.
-- Assumes that substitution has been applied
solveIsNeg' :: Ord a => (Provenance a, Term) -> S a ()
solveIsNeg' (proof,t)

  -- A < 0
  | Just a <- isConst t = guarded proof (a < 0)

  -- A * S < 0
  -- This does not mess with new variables, so we don't need
  -- to re-apply the substitution.
  -- Note: the constant is positive, so `s` must be negative.
  | Just (_,s) <- tFactor t = solveIsNeg' (proof,s)

  -- See Section 5.1 of the paper.
  | Just (xc,x,s) <- tLeastVar t =

    do ctrs <- if xc < 0
               -- -XC*x + S < 0
               -- S < XC*x
               then do ubs <- getBounds Upper x
                       let b    = negate xc
                           beta = s
                       addBound Lower x (Bound proof b beta)
                       return [ (p, a,alpha,b,beta) | Bound p a alpha <- ubs ]

               -- XC*x + S < 0
               -- XC*x < -S
               else do lbs <- getBounds Lower x
                       let a     = xc
                           alpha = tNeg s
                       addBound Upper x (Bound proof a alpha)
                       return [ (p,a,alpha,b,beta) | Bound p b beta <- lbs ]

      -- See Note [Shadows]
       forM_ ctrs (\(p,a,alpha,b,beta) ->
          do let p1   = usesBoth proof p
                 real = ctLt (a |*| beta) (b |*| alpha)
                 dark = ctLt (tConst (a * b)) (b |*| alpha |-| a |*| beta)
                 gray = [ ctEq (b |*| tVar x) (tConst i |+| beta)
                                                      | i <- [ 1 .. b - 1 ] ]
             solveIsNeg (p1,real)
             delay ShadowCt { darkShadow = (p1,dark)
                            , grayShadow = map ((,) p1) gray
                            }
             )

  | otherwise = error "solveIsNeg: unreachable"


{- Note [Shadows]

  P: beta < b * x
  Q: a * x < alpha

real: a * beta < b * alpha

  beta     < b * x      -- from P
  a * beta < a * b * x  -- (a *)
  a * beta < b * alpha  -- comm. and Q


dark: b * alpha - a * beta > a * b


gray: b * x = beta + 1 \/
      b * x = beta + 2 \/
      ...
      b * x = beta + (b-1)

We stop at @b - 1@ because if:

> b * x                >= beta + b
> a * b * x            >= a * (beta + b)     -- (a *)
> a * b * x            >= a * beta + a * b   -- distrib.
> b * alpha            >  a * beta + a * b   -- comm. and Q
> b * alpha - a * beta > a * b               -- subtract (a * beta)

which is covered by the dark shadow.
-}


-- | A disjunction of constraints.
data ShadowCt a = ShadowCt { darkShadow :: (Provenance a,Term)
                              -- ^ this is negative
                           , grayShadow :: [(Provenance a,Term)]
                             -- ^ these are 0
                           } deriving Show



--------------------------------------------------------------------------------
-- Monad

newtype S p a   = S { runS :: RW p -> Answer p a }

data RW p       = RW { nameSource :: !Int
                     , inerts     :: !(Inerts p)
                     , delayed    :: ![ShadowCt p]
                     } deriving Show

data Answer p a = Error !(Provenance p)
                | Ok a !(RW p)

instance Monad (S p) where
  return a      = S $ \s -> Ok a s
  fail s        = error s
  S m >>= k     = S $ \s -> case m s of
                              Ok a s1 -> let S m1 = k a
                                         in m1 s1
                              Error e  -> Error e

instance Functor (S p) where
  fmap = liftM

instance Applicative (S p) where
  pure  = return
  (<*>) = ap

initRW :: RW p
initRW = RW { nameSource = 0, inerts = iNone, delayed = [] }

failure :: Provenance p -> S p ()
failure msg = S $ \_ -> Error msg

guarded :: Provenance p -> Bool -> S p ()
guarded msg ok = if ok then return () else failure msg

updS :: (RW p -> (a,RW p)) -> S p a
updS f = S $ \s -> case f s of
                     (a,s1) -> Ok a s1

updS_ :: (RW p -> RW p) -> S p ()
updS_ f = updS $ \rw -> ((), f rw)

get :: (RW p -> a) -> S p a
get f = updS $ \rw -> (f rw, rw)

newVar :: S p Name
newVar = updS $ \rw -> ( SysName (nameSource rw)
                       , rw { nameSource = nameSource rw + 1 }
                       )

-- | Get lower ('fst'), or upper ('snd') bounds for a variable.
getBounds :: BoundType -> Name -> S p [Bound p]
getBounds f x = get $ \rw -> case Map.lookup x $ bounds $ inerts rw of
                               Nothing -> []
                               Just bs -> case f of
                                            Lower -> fst bs
                                            Upper -> snd bs

-- | Add an upper or lower bound on a given (multiple of a) variable.
addBound :: BoundType -> Name -> Bound p -> S p ()
addBound bt x b = updS_ $ \rw ->
  let i     = inerts rw
      entry = case bt of
                Lower -> ([b],[])
                Upper -> ([],[b])
      jn (newL,newU) (oldL,oldU) = (newL++oldL, newU++oldU)
  in rw { inerts = i { bounds = Map.insertWith jn x entry (bounds i) }}

-- | Add a new definition.
-- Assumes substitution has already been applied
addDef :: Ord p => Provenance p -> Name -> Term -> S p ()
addDef proof x t =
  do newWork <- updS $ \rw ->
      let (newWork,newInerts) = iSolved proof x t (inerts rw)

          apS d = ShadowCt
                    { darkShadow =      (iApSubst newInerts) (darkShadow d)
                    , grayShadow = fmap (iApSubst newInerts) (grayShadow d)
                    }
      in (newWork, rw { inerts = newInerts, delayed = map apS (delayed rw) })
     mapM_ solveIsNeg newWork

-- | Apply the current substitution to this term.
apSubst :: Ord p => (Provenance p, Term) -> S p (Provenance p, Term)
apSubst t =
  do i <- get inerts
     return (iApSubst i t)

-- | Add a shadow constraint to solve later.
delay :: ShadowCt p -> S p ()
delay ct = updS_ (\rw -> rw { delayed = ct : delayed rw })



--------------------------------------------------------------------------------


{- | The provenance for an assertion keeps track of all other basic assertions
that were used to construct it.   When we find a contradiction,
we use the provenance to find which basic assertions lead to the conflict. -}
newtype Provenance lit = Provenance (Set lit)

instance Show lit => Show (Provenance lit) where
  showsPrec p prov = showsPrec p (provenance prov)

-- | The provenance for a basic assetion.
basicAssert :: lit -> Provenance lit
basicAssert n = Provenance (Set.singleton n)

-- | Combine the multiple assertions together.
usesBoth :: Ord lit => Provenance lit -> Provenance lit -> Provenance lit
usesBoth (Provenance x) (Provenance y) = Provenance (Set.union x y)


-- | Pretty print a provenance set.
ppProvenance :: (lit -> Doc) -> Provenance lit -> Doc
ppProvenance pp (Provenance x) =
  brackets $ sep $ punctuate comma $ map pp $ Set.toList x

-- | The basic assertions in this provenance set.
provenance :: Provenance lit -> Set lit
provenance (Provenance x) = x


--------------------------------------------------------------------------------
-- Terms

data Name = UserName !Int | SysName !Int
            deriving (Read,Show,Eq,Ord)

ppName :: Name -> Doc
ppName (UserName x) = text "u" <> int x
ppName (SysName x)  = text "s" <> int x

toName :: Int -> Name
toName = UserName

fromName :: Name -> Maybe Int
fromName (UserName x) = Just x
fromName (SysName _)  = Nothing




-- | The type of terms.  The integer is the constant part of the term,
-- and the `Map` maps variables (represented by @Int@ to their coefficients).
-- The term is a sum of its parts.
-- INVARIANT: the `Map` does not map anything to 0.
data Term = T !Integer (Map Name Integer)
              deriving (Eq,Ord)

infixl 6 |+|, |-|
infixr 7 |*|

-- | A numeric literal.
tConst :: Integer -> Term
tConst k = T k Map.empty

-- | An uninterpreted constant.
tVar :: Name -> Term
tVar x = T 0 (Map.singleton x 1)

-- | Add two terms.
(|+|) :: Term -> Term -> Term
T n1 m1 |+| T n2 m2 = T (n1 + n2)
                    $ if Map.null m1 then m2 else
                      if Map.null m2 then m1 else
                      Map.filter (/= 0) $ Map.unionWith (+) m1 m2

-- | Multiple a constant with a term.
(|*|) :: Integer -> Term -> Term
0 |*| _     = tConst 0
1 |*| t     = t
k |*| T n m = T (k * n) (fmap (k *) m)

-- | Negate a term.
tNeg :: Term -> Term
tNeg t = (-1) |*| t

-- | Subtract two terms.
(|-|) :: Term -> Term -> Term
t1 |-| t2 = t1 |+| tNeg t2

-- | Replace a variable with a term.
tLet :: Name -> Term -> Term -> Term
tLet x t1 t2 = let (a,t) = tSplitVar x t2
               in a |*| t1 |+| t

-- | Replace a variable with a term, return `Nothing`, if no change.
tLet' :: Name -> Term -> Term -> Maybe Term
tLet' x t1 t2 = do let (a,t) = tSplitVar x t2
                   guard (a /= 0)
                   return (a |*| t1 |+| t)

-- | Replace a variable with a numeric literal.
tLetNum :: Name -> Integer -> Term -> Term
tLetNum x k t = let (c,T n m) = tSplitVar x t
                in T (c * k + n) m

-- | Replace the given variables with constants.
tLetNums :: [(Name,Integer)] -> Term -> Term
tLetNums xs t = foldr (\(x,i) t1 -> tLetNum x i t1) t xs




instance Show Term where
  showsPrec c t = showsPrec c (show (ppTerm t))

-- | Pretty-print a term.
ppTerm :: Term -> Doc
ppTerm (T k m) =
  case Map.toList m of
    [] -> integer k
    xs | k /= 0 -> hsep (integer k : map ppProd xs)
    x : xs      -> hsep (ppFst x   : map ppProd xs)

  where
  ppFst (x,1)   = ppName x
  ppFst (x,-1)  = text "-" <> ppName x
  ppFst (x,n)   = ppMul n x

  ppProd (x,1)  = text "+" <+> ppName x
  ppProd (x,-1) = text "-" <+> ppName x
  ppProd (x,n) | n > 0      = text "+" <+> ppMul n x
               | otherwise  = text "-" <+> ppMul (abs n) x

  ppMul n x = integer n <+> text "*" <+> ppName x

-- | Remove a variable from the term and return its coefficient.
-- If the variable is not present in the term, then the coefficient is 0.
tSplitVar :: Name -> Term -> (Integer, Term)
tSplitVar x t@(T n m) =
  case Map.updateLookupWithKey (\_ _ -> Nothing) x m of
    (Nothing,_) -> (0,t)
    (Just k,m1) -> (k, T n m1)

-- | Does the term contain this varibale?
tHasVar :: Name -> Term -> Bool
tHasVar x (T _ m) = Map.member x m

-- | Is this terms just an integer?
isConst :: Term -> Maybe Integer
isConst (T n m)
  | Map.null m  = Just n
  | otherwise   = Nothing

-- | The constant in a term.
tConstPart :: Term -> Integer
tConstPart (T n _) = n

-- | Returns: @Just (a, b, x)@ if the term is the form: @a + b * x@
tIsOneVar :: Term -> Maybe (Integer, Integer, Name)
tIsOneVar (T a m) = case Map.toList m of
                      [ (x,b) ] -> Just (a, b, x)
                      _         -> Nothing

-- | Spots terms that contain variables with unit coefficients
-- (i.e., of the form @x + t@ or @t - x@).
-- Returns (coeff, var, rest of term)
tGetSimpleCoeff :: Term -> Maybe (Integer, Name, Term)
tGetSimpleCoeff (T a m) =
  do let (m1,m2) = Map.partition (\x -> x == 1 || x == -1) m
     ((x,xc), m3) <- Map.minViewWithKey m1
     return (xc, x, T a (Map.union m3 m2))

-- | The variables mentioned in this term.
tVarList :: Term -> [Name]
tVarList (T _ m) = Map.keys m

-- | Try to factor-out a common constant, (> 1), from a term.
-- For example, @2 + 4*x@ becomes @2 * (1 + 2x)@.
tFactor :: Term -> Maybe (Integer, Term)
tFactor (T c m) =
  do d <- common (c : Map.elems m)
     return (d, T (div c d) (fmap (`div` d) m))
  where
  common :: [Integer] -> Maybe Integer
  common []  = Nothing
  common [x] = Just x
  common (x : y : zs) =
    case gcd x y of
      1 -> Nothing
      n -> common (n : zs)

-- | Extract a variable with a coefficient whose absolute value is minimal.
tLeastAbsCoeff :: Term -> Maybe (Integer, Name, Term)
tLeastAbsCoeff (T c m) = do (xc,x,m1) <- Map.foldWithKey step Nothing m
                            return (xc, x, T c m1)
  where
  step x xc Nothing   = Just (xc, x, Map.delete x m)
  step x xc (Just (yc,_,_))
    | abs xc < abs yc = Just (xc, x, Map.delete x m)
  step _ _ it         = it

-- | Extract the least variable from a term
tLeastVar :: Term -> Maybe (Integer, Name, Term)
tLeastVar (T c m) =
  do ((x,xc), m1) <- Map.minViewWithKey m
     return (xc, x, T c m1)

-- | Apply a function to all coefficients, including the constant.
tMapCoeff :: (Integer -> Integer) -> Term -> Term
tMapCoeff f (T c m) = T (f c) (fmap f m)



