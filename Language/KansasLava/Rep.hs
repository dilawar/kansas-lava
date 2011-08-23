{-# LANGUAGE TypeFamilies, ExistentialQuantification, FlexibleInstances, UndecidableInstances, FlexibleContexts, DeriveDataTypeable,
    ScopedTypeVariables, MultiParamTypeClasses, FunctionalDependencies,ParallelListComp, TypeSynonymInstances, TypeOperators  #-}
-- | KansasLava is designed for generating hardware circuits. This module
-- provides a 'Rep' class that allows us to model, in the shallow embedding of
-- KL, two important features of hardware signals. First, all signals must have
-- some static width, as they will be synthsized to a collection of hardware
-- wires. Second, a value represented by a signal may be unknown, in part or in
-- whole.
module Language.KansasLava.Rep where

import Language.KansasLava.Types
import Control.Monad (liftM)
import Data.Sized.Arith
import Data.Sized.Ix
import Data.Sized.Matrix hiding (S)
import qualified Data.Sized.Matrix as M
import Data.Sized.Unsigned as U
import Data.Sized.Signed as S
import Data.Word
import qualified Data.Maybe as Maybe
import Data.Traversable(sequenceA)
import qualified Data.Sized.Sampled as Sampled


-- | A 'Rep a' is an 'a' value that we 'Rep'resent, aka we can push it over a
-- wire. The general idea is that instances of Rep should have a width (for the
-- corresponding bitvector representation) and that Rep instances should be able
-- to represent the "unknown" -- X -- value. For example, Bools can be
-- represented with one bit, and the inclusion of the unknown X value
-- corresponds to three-valued logic.
class {- (Size (W w)) => -} Rep w where
    -- | the width of the represented value, as a type-level number.
    type W w

    -- | X are lifted inputs to this wire.
    data X w

    -- | check for bad things.
    unX :: X w -> Maybe w

    -- | and, put the good or bad things back.
    optX :: Maybe w -> X w

    -- | convert to binary (rep) format
    toRep   :: X w -> RepValue

    -- | convert from binary (rep) format
    fromRep :: RepValue -> X w

    -- | Each wire has a known type.
    repType :: Witness w -> Type

    -- show the value (in its Haskell form, default is the bits)
    showRep :: X w -> String
    showRep x = show (toRep x)

-- | Given a witness of a representable type, generate all (2^n) possible values of that type.
allReps :: (Rep w) => Witness w -> [RepValue]
allReps w = [ RepValue (fmap Just count) | count <- counts n ]
   where
    n = repWidth w
    counts :: Int -> [[Bool]]
    counts 0 = [[]]
    counts num = [ x : xs |  xs <- counts (num-1), x <- [False,True] ]

-- | Figure out the width in bits of a type.
repWidth :: (Rep w) => Witness w -> Int
repWidth w = typeWidth (repType w)


-- | unknownRepValue returns a RepValue that is completely filled with 'X'.
unknownRepValue :: (Rep w) => Witness w -> RepValue
unknownRepValue w = RepValue [ Nothing | _ <- [1..repWidth w]]

-- | Check to see if all bits in a bitvector (represented as a Matrix) are
-- valid. Returns Nothing if any of the bits are unknown.
allOkayRep :: (Size w) => Matrix w (X Bool) -> Maybe (Matrix w Bool)
allOkayRep m = sequenceA $ fmap prj m
  where prj (XBool Nothing) = Nothing
        prj (XBool (Just v)) = Just v

-- | pureX lifts a value to a (known) representable value.
pureX :: (Rep w) => w -> X w
pureX = optX . Just

-- | unknownX is an unknown value of every representable type.
unknownX :: forall w . (Rep w) => X w
unknownX = optX (Nothing :: Maybe w)

-- | liftX converts a function over values to a function over possibly unknown values.
liftX :: (Rep a, Rep b) => (a -> b) -> X a -> X b
liftX f = optX . liftM f . unX



-- | showRepDefault will print a Representable value, with "?" for unknown.
-- This is not wired into the class because of the extra 'Show' requirement.
showRepDefault :: forall w. (Show w, Rep w) => X w -> String
showRepDefault v = case unX v :: Maybe w of
            Nothing -> "?"
            Just v' -> show v'

-- | Convert an integral value to a RepValue -- its bitvector representation.
toRepFromIntegral :: forall v . (Rep v, Integral v) => X v -> RepValue
toRepFromIntegral v = case unX v :: Maybe v of
                 Nothing -> unknownRepValue (Witness :: Witness v)
                 Just v' -> RepValue
                    $ take (repWidth (Witness :: Witness v))
                    $ map (Just . odd)
                    $ iterate (`div` (2::Int))
                    $ fromIntegral v'
-- | Convert a RepValue representing an integral value to a representable value
-- of that integral type.
fromRepToIntegral :: forall v . (Rep v, Integral v) => RepValue -> X v
fromRepToIntegral r =
    optX (fmap (\ xs ->
        sum [ n
                | (n,b) <- zip (iterate (* 2) 1)
                       xs
                , b
                ])
          (getValidRepValue r) :: Maybe v)

-- | fromRepToInteger always a positve number, unknowns defin
fromRepToInteger :: RepValue -> Integer
fromRepToInteger (RepValue xs) =
        sum [ n
                | (n,b) <- zip (iterate (* 2) 1)
                       xs
                , case b of
            Nothing -> False
            Just True -> True
            Just False -> False
                ]


-- | Compare a golden value with a generated value.
cmpRep :: (Rep a) => X a -> X a -> Bool
cmpRep g v = toRep g `cmpRepValue` toRep v

------------------------------------------------------------------------------------

instance Rep Bool where
    type W Bool     = X1
    data X Bool     = XBool (Maybe Bool)
    optX (Just b)   = XBool $ return b
    optX Nothing    = XBool $ fail "Wire Bool"
    unX (XBool (Just v))  = return v
    unX (XBool Nothing) = fail "Wire Bool"
    repType _  = B
    toRep (XBool v)   = RepValue [v]
    fromRep (RepValue [v]) = XBool v
    fromRep rep    = error ("size error for Bool : " ++ show (Prelude.length $ unRepValue rep) ++ " " ++ show rep)

instance Rep Int where
    type W Int     = X32
    data X Int  = XInt (Maybe Int)
    optX (Just b)   = XInt $ return b
    optX Nothing    = XInt $ fail "Wire Int"
    unX (XInt (Just v))  = return v
    unX (XInt Nothing) = fail "Wire Int"
    repType _  = S 32      -- hmm. Not really on 64 bit machines.

    toRep = toRepFromIntegral
    fromRep = fromRepToIntegral
    showRep = showRepDefault

instance Rep Word8 where
    type W Word8     = X8
    data X Word8    = XWord8 (Maybe Word8)
    optX (Just b)   = XWord8 $ return b
    optX Nothing    = XWord8 $ fail "Wire Word8"
    unX (XWord8 (Just v))  = return v
    unX (XWord8 Nothing) = fail "Wire Word8"
    repType _  = U 8
    toRep = toRepFromIntegral
    fromRep = fromRepToIntegral
    showRep = showRepDefault

instance Rep Word32 where
    type W Word32     = X32
    data X Word32   = XWord32 (Maybe Word32)
    optX (Just b)   = XWord32 $ return b
    optX Nothing    = XWord32 $ fail "Wire Word32"
    unX (XWord32 (Just v)) = return v
    unX (XWord32 Nothing) = fail "Wire Word32"
    repType _  = U 32
    toRep = toRepFromIntegral
    fromRep = fromRepToIntegral
    showRep = showRepDefault

instance Rep () where
    type W ()     = X0
    data X ()   = XUnit (Maybe ())
    optX (Just b)   = XUnit $ return b
    optX Nothing    = XUnit $ fail "Wire ()"
    unX (XUnit (Just v))  = return v
    unX (XUnit Nothing) = fail "Wire ()"
    repType _  = V 1   -- should really be V 0 TODO
    toRep _ = RepValue []
    fromRep _ = XUnit $ return ()
    showRep _ = "()"

-- | Integers are unbounded in size. We use the type 'IntegerWidth' as the
-- associated type representing this size in the instance of Rep for Integers.
data IntegerWidth = IntegerWidth

instance Rep Integer where
    type W Integer  = IntegerWidth
    data X Integer  = XInteger Integer   -- No fail/unknown value
    optX (Just b)   = XInteger b
    optX Nothing    = XInteger $ error "Generic failed in optX"
    unX (XInteger a)       = return a
    repType _  = GenericTy
    toRep = error "can not turn a Generic to a Rep"
    fromRep = error "can not turn a Rep to a Generic"
    showRep (XInteger v) = show v

-------------------------------------------------------------------------------------
-- Now the containers

-- TODO: fix this to use :> as the basic internal type.

instance (Rep a, Rep b) => Rep (a :> b) where
    type W (a :> b)  = ADD (W a) (W b)
    data X (a :> b)     = XCell (X a, X b)
    optX (Just (a :> b))   = XCell (pureX a, pureX b)
    optX Nothing        = XCell (optX (Nothing :: Maybe a), optX (Nothing :: Maybe b))
    unX (XCell (a,b)) = do x <- unX a
                           y <- unX b
                           return (x :> y)

    repType Witness = TupleTy [repType (Witness :: Witness a), repType (Witness :: Witness b)]

    toRep (XCell (a,b)) = RepValue (avals ++ bvals)
        where (RepValue avals) = toRep a
              (RepValue bvals) = toRep b
    fromRep (RepValue vs) = XCell ( fromRep (RepValue (take size_a vs))
                  , fromRep (RepValue (drop size_a vs))
                  )
        where size_a = typeWidth (repType (Witness :: Witness a))
    showRep (XCell (a,b)) = showRep a ++ " :> " ++ showRep b


instance (Rep a, Rep b) => Rep (a,b) where
    type W (a,b)  = ADD (W a) (W b)
    data X (a,b)        = XTuple (X a, X b)
    optX (Just (a,b))   = XTuple (pureX a, pureX b)
    optX Nothing        = XTuple (optX (Nothing :: Maybe a), optX (Nothing :: Maybe b))
    unX (XTuple (a,b)) = do x <- unX a
                            y <- unX b
                            return (x,y)

    repType Witness = TupleTy [repType (Witness :: Witness a), repType (Witness :: Witness b)]

    toRep (XTuple (a,b)) = RepValue (avals ++ bvals)
        where (RepValue avals) = toRep a
              (RepValue bvals) = toRep b
    fromRep (RepValue vs) = XTuple ( fromRep (RepValue (take size_a vs))
                  , fromRep (RepValue (drop size_a vs))
                  )
        where size_a = typeWidth (repType (Witness :: Witness a))
    showRep (XTuple (a,b)) = "(" ++ showRep a ++ "," ++ showRep b ++ ")"

instance (Rep a, Rep b, Rep c) => Rep (a,b,c) where
    type W (a,b,c) = ADD (W a) (ADD (W b) (W c))
    data X (a,b,c)      = XTriple (X a, X b, X c)
    optX (Just (a,b,c))     = XTriple (pureX a, pureX b,pureX c)
    optX Nothing        = XTriple ( optX (Nothing :: Maybe a),
                    optX (Nothing :: Maybe b),
                    optX (Nothing :: Maybe c) )
    unX (XTriple (a,b,c))
          = do x <- unX a
               y <- unX b
               z <- unX c
               return (x,y,z)

    repType Witness = TupleTy [repType (Witness :: Witness a), repType (Witness :: Witness b),repType (Witness :: Witness c)]
    toRep (XTriple (a,b,c)) = RepValue (avals ++ bvals ++ cvals)
        where (RepValue avals) = toRep a
              (RepValue bvals) = toRep b
              (RepValue cvals) = toRep c
    fromRep (RepValue vs) = XTriple ( fromRep (RepValue (take size_a vs))
				  , fromRep (RepValue (take size_b (drop size_a vs)))
                  , fromRep (RepValue (drop (size_a + size_b) vs))
                  )
        where size_a = typeWidth (repType (Witness :: Witness a))
              size_b = typeWidth (repType (Witness :: Witness b))
    showRep (XTriple (a,b,c)) = "(" ++ showRep a ++
                "," ++ showRep b ++
                "," ++ showRep c ++ ")"

instance (Rep a) => Rep (Maybe a) where
    type W (Maybe a) = ADD (W a) X1
    -- not completely sure about this representation
    data X (Maybe a) = XMaybe (X Bool, X a)
    optX b      = XMaybe ( case b of
                  Nothing -> optX (Nothing :: Maybe Bool)
                  Just Nothing   -> optX (Just False :: Maybe Bool)
                  Just (Just {}) -> optX (Just True :: Maybe Bool)
              , case b of
                Nothing       -> optX (Nothing :: Maybe a)
                Just Nothing  -> optX (Nothing :: Maybe a)
                Just (Just a) -> optX (Just a :: Maybe a)
              )
    unX (XMaybe (a,b))   = case unX a :: Maybe Bool of
                Nothing    -> Nothing
                Just True  -> Just $ unX b
                Just False -> Just Nothing
    repType _  = TupleTy [ B, repType (Witness :: Witness a)]

    toRep (XMaybe (a,b)) = RepValue (avals ++ bvals)
        where (RepValue avals) = toRep a
              (RepValue bvals) = toRep b
    fromRep (RepValue vs) = XMaybe ( fromRep (RepValue (take 1 vs))
                  , fromRep (RepValue (drop 1 vs))
                  )
    showRep (XMaybe (XBool Nothing,_a)) = "?"
    showRep (XMaybe (XBool (Just True),a)) = "Just " ++ showRep a
    showRep (XMaybe (XBool (Just False),_)) = "Nothing"

instance (Size ix, Rep a) => Rep (Matrix ix a) where
    type W (Matrix ix a) = MUL ix (W a)
    data X (Matrix ix a) = XMatrix (Matrix ix (X a))
    optX (Just m)   = XMatrix $ fmap (optX . Just) m
    optX Nothing    = XMatrix $ forAll $ \ _ -> optX (Nothing :: Maybe a)
    unX (XMatrix m) = liftM matrix $ mapM (\ i -> unX (m ! i)) (indices m)
    repType Witness = MatrixTy (size (error "witness" :: ix)) (repType (Witness :: Witness a))
    toRep (XMatrix m) = RepValue (concatMap (unRepValue . toRep) $ M.toList m)
    fromRep (RepValue xs) = XMatrix $ M.matrix $ fmap (fromRep . RepValue) $ unconcat xs
	    where unconcat [] = []
		  unconcat ys = take len ys : unconcat (drop len ys)

		  len = Prelude.length xs `div` size (error "witness" :: ix)

--  showWire _ = show
instance (Size ix) => Rep (Unsigned ix) where
    type W (Unsigned ix) = ix
    data X (Unsigned ix) = XUnsigned (Maybe (Unsigned ix))
    optX (Just b)       = XUnsigned $ return b
    optX Nothing        = XUnsigned $ fail "Wire Int"
    unX (XUnsigned (Just a))     = return a
    unX (XUnsigned Nothing)   = fail "Wire Int"
    repType _          = U (size (error "Wire/Unsigned" :: ix))
    toRep = toRepFromIntegral
    fromRep = fromRepToIntegral
    showRep = showRepDefault

instance (Size ix) => Rep (Signed ix) where
    type W (Signed ix) = ix
    data X (Signed ix) = XSigned (Maybe (Signed ix))
    optX (Just b)       = XSigned $ return b
    optX Nothing        = XSigned $ fail "Wire Int"
    unX (XSigned (Just a))     = return a
    unX (XSigned Nothing)   = fail "Wire Int"
    repType _          = S (size (error "Wire/Signed" :: ix))
    toRep = toRepFromIntegral
    fromRep = fromRepToIntegral
    showRep = showRepDefault

-----------------------------------------------------------------------------
-- The grandfather of them all, functions.

instance (Size ix, Rep a, Rep ix) => Rep (ix -> a) where
    type W (ix -> a) = MUL ix (W a)
    data X (ix -> a) = XFunction (ix -> X a)

    optX (Just f) = XFunction $ \ ix -> optX (Just (f ix))
    optX Nothing    = XFunction $ const (optX Nothing)

    -- assumes total function
    unX (XFunction f) = return (Maybe.fromJust . unX . f)

    repType Witness = MatrixTy (size (error "witness" :: ix)) (repType (Witness :: Witness a))

    -- reuse the matrix encodings here
    -- TODO: work out how to remove the Size ix constraint,
    -- and use Rep ix somehow instead.
    toRep (XFunction f) = toRep (XMatrix $ M.forAll f)
    fromRep (RepValue xs) = XFunction $ \ ix ->
	case fromRep (RepValue xs) of
	   XMatrix m -> m M.! ix

-----------------------------------------------------------------------------

-- | Calculate the base-2 logrithim of a integral value.
log2 :: (Integral a) => a -> a
log2 0 = 0
log2 1 = 1
log2 n = log2 (n `div` 2) + 1

-- Perhaps not, because what does X0 really mean over a wire, vs X1.
instance Rep X0 where
    type W X0 = X0
    data X X0 = X0'
    optX _ = X0'
    unX X0' = return X0
    repType _  = V 0
    toRep = toRepFromIntegral
    fromRep = fromRepToIntegral
    showRep = showRepDefault

instance (Integral x, Size x) => Rep (X0_ x) where
    type W (X0_ x) = LOG (SUB (X0_ x) X1)
    data X (X0_ x)  = XX0 (Maybe (X0_ x))
    optX (Just x)   = XX0 $ return x
    optX Nothing    = XX0 $ fail "X0_"
    unX (XX0 (Just a)) = return a
    unX (XX0 Nothing) = fail "X0_"
    repType _  = U (log2 (size (error "repType" :: X0_ x) - 1))
    toRep = toRepFromIntegral
    fromRep = sizedFromRepToIntegral
    showRep = showRepDefault

instance (Integral x, Size x) => Rep (X1_ x) where
    type W (X1_ x)  = LOG (SUB (X1_ x) X1)
    data X (X1_ x)  = XX1 (Maybe (X1_ x))
    optX (Just x)   = XX1 $ return x
    optX Nothing    = XX1 $ fail "X1_"
    unX (XX1 (Just a)) = return a
    unX (XX1 Nothing) = fail "X1_"
    repType _  = U (log2 (size (error "repType" :: X1_ x) - 1))
    toRep = toRepFromIntegral
    fromRep = sizedFromRepToIntegral
    showRep = showRepDefault

-- | This is a version of fromRepToIntegral that
-- check to see if the result is inside the size bounds.
sizedFromRepToIntegral :: forall w . (Rep w, Integral w, Size w) => RepValue -> X w
sizedFromRepToIntegral w
        | val_integer >= toInteger (size (error "witness" :: w)) = unknownX
        | otherwise                                             = val
  where
        val_integer :: Integer
        val_integer = fromRepToInteger w

        val :: X w
        val = fromRepToIntegral w

-----------------------------------------------------------------

instance (Enum ix, Size m, Size ix) => Rep (Sampled.Sampled m ix) where
        type W (Sampled.Sampled m ix) = ix
	data X (Sampled.Sampled m ix) = XSampled (Maybe (Sampled.Sampled m ix))
	optX (Just b)	    = XSampled $ return b
	optX Nothing	    = XSampled $ fail "Wire Sampled"
	unX (XSampled (Just a))     = return a
	unX (XSampled Nothing)   = fail "Wire Sampled"
	repType _   	    = SampledTy (size (error "witness" :: m)) (size (error "witness" :: ix))
	toRep (XSampled Nothing) = unknownRepValue (Witness :: Witness (Sampled.Sampled m ix))
	toRep (XSampled (Just a))   = RepValue $ fmap Just $ M.toList $ Sampled.toMatrix a
	fromRep r = optX (liftM (Sampled.fromMatrix . M.fromList) $ getValidRepValue r)
	showRep = showRepDefault

