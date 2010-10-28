{-# LANGUAGE TypeFamilies, FlexibleInstances,ParallelListComp, ScopedTypeVariables #-}
module Language.KansasLava.Reify
	( reifyCircuit
	, Ports(..)
	, Input(..)
	, input
	, output
	) where

import Data.Default
import Data.List as L
import qualified Data.Map as Map
import Data.Reify

import Language.KansasLava.Circuit
import Language.KansasLava.Circuit.Depth
import Language.KansasLava.Circuit.Optimization
import Language.KansasLava.Entity
import Language.KansasLava.Entity.Utils
import Language.KansasLava.Wire
import Language.KansasLava.Comb
import Language.KansasLava.Seq
import Language.KansasLava.Signal
import qualified Language.KansasLava.Stream as Stream
import Language.KansasLava.Types
import Language.KansasLava.Utils
import Language.KansasLava.Handshake

import Data.Sized.Matrix as M

import Debug.Trace

-- | 'reifyCircuit' does reification on a function into a 'Circuit'.
--
reifyCircuit :: (Ports a) => a -> IO Circuit
reifyCircuit circuit = do

	let opts = []
        -- GenSym for input/output pad names
	let inputNames = L.zipWith OVar [0..] $ head $
		[[ "i" ++ show i | i <- [0..]]]
	let outputNames =  L.zipWith OVar [0..] $ head $
		 [[ "o" ++ show i | i <- [0..]]]

	let os = ports 0 circuit

	let o = Port ("o0")
            	$ E
            	$ Entity (Name "Lava" "top") [("o0",B)]	-- not really a Bit
             	[ ("i" ++ show i,tys, dr)
	     	| (i,(tys,dr)) <- zip [0..] os
             	]
             	[]

        -- Get the graph, and associate the output drivers for the graph with
        -- output pad names.
        (gr, outputs) <- case o of
                Port _ o' -> do
                   (Graph gr out) <- reifyGraph o'
		   let gr' = [ (nid,nd) | (nid,nd) <- gr
				        , nid /= out
			     ]
		   case lookup out gr of
                     Just (Entity (Name "Lava" "top")  _ ins _) ->
                       return $ (gr',[(sink,ity, driver)
                                       | (_,ity,driver) <- ins
                                       | sink <- outputNames
				       ])
		     -- if the circuit is trivial??
                     Just (Entity (Name _ _) outs _ _) ->
                       return $ (gr', [(sink,oty, Port ovar out)
                                      | (ovar,oty) <- outs
                                      | sink <- outputNames
				      ])
                     _ -> error $ "reifyCircuit: " ++ show o
		-- TODO: restore this
--                (Lit x) -> return ([],[((head outputNames),ty,Lit x)])
                v -> fail $ "reifyGraph failed in reifyCircuit" ++ show v

--	print outputs

	let newOut = 1 + maximum ((-1) : [ i | (OVar i _,_,_) <- outputs ])
--	print newOut

	let backoutputs =
	      [ (OVar n ("b" ++ show n), vTy, dr)
	      | (i,Entity (Prim "hof") _ [(v,vTy,dr)] _) <- gr
	      | n <- [newOut..]
	      ]

	let outputs2 = outputs ++ backoutputs
	let outputs = outputs2

	let hofs =
	      [ i
	      | (i,Entity (Prim "hof") _ [(v,vTy,dr)] _)  <- gr
	      ]
--	print hofs

	let findHof i = case Prelude.lookup i (zip hofs [newOut..]) of
			   Nothing -> error $ "can not find hof : " ++ show i
			   Just v -> OVar v ("o" ++ show v)


	let remap_hofs (nm,ty,Port pnm i)
	        | i `elem` hofs = (nm,ty,Pad $ findHof i)
		| otherwise = (nm,ty,Port pnm i)
	    remap_hofs other = other

	let gr' = [ ( i
	            , case g of
			 Entity nm outs ins g ->
				Entity nm outs (map remap_hofs ins) g
		    )
		  | (i,g) <- gr
		  , not (i `elem` hofs)
		  ]
	let gr = gr'

        -- Search all of the enities, looking for input ports.
        let inputs = [ (v,vTy) | (_,Entity nm _ ins _) <- gr
			       , (_,vTy,Pad v) <- ins]

        let rCit = Circuit { theCircuit = gr
                                  , theSrcs = nub inputs
                                  , theSinks = outputs
                                  }


	let rCit' = resolveNames rCit
	let rCit = rCit'

--	print rCit
	rCit2 <- if OptimizeReify `elem` opts then optimizeCircuit def rCit else return rCit

	let depthss = [ mp | CommentDepth mp <- opts ]


	rCit3 <- case depthss of
		    [depths]  -> do let chains = findChains (depths ++ depthTable) rCit2
				        env = Map.fromList [ (u,d) | (d,u) <- concat chains ]
				    return $ rCit2 { theCircuit = [ (u,case e of
					 	          Entity nm ins outs ann ->
								case Map.lookup u env of
								  Nothing -> e
								  Just d -> Entity nm ins outs (ann ++ [Comment $ "depth: " ++ show d])
							  _ -> e)
						     | (u,e) <- theCircuit rCit2
						     ]}
		    []        -> return rCit2

	return $ rCit3

wireCapture :: forall w . (Rep w) => D w -> [(Type, Driver E)]
wireCapture (D d) = [(wireType (error "wireCapture" :: w), d)]


showCircuit :: (Ports circuit) => [CircuitOptions] -> circuit -> IO String
showCircuit opt c = do
	rCir <- reifyCircuit c
	return $ show rCir

debugCircuit :: (Ports circuit) => [CircuitOptions] -> circuit -> IO ()
debugCircuit opt c = showCircuit opt c >>= putStr

-- | The 'Ports' class generates input pads for a function type, so that the
-- function can be Reified. The result of the circuit, as a driver, as well as
-- the result's type, are returned. I _think_ this takes the place of the REIFY
-- typeclass, but I'm not really sure.

class Ports a where
  ports :: Int -> a -> [(Type, Driver E)]

class Input a where
    inPorts :: Int -> (a, Int)

    getSignal :: TraceStream -> a
    getSignal _ = error "Input: getSignal, no instance"

    apply :: TraceMap k -> (a -> b) -> (TraceMap k, b)
    apply _ _ = error "Input: apply, no instance"

    input :: String -> a -> a

class BackPorts a where
--    inPorts :: Int -> (a, Int)
--    input :: String -> a -> a

{-
instance (BackPorts a, Input b) => Input (a -> b) where
     -- inPorts :: Int -> (a -> b,Int)

	inPorts v = (,)

	error "XX"
--    inPorts :: Int -> (a, Int)
--    input :: String -> a -> a
	input _ a = a
-}

-- Royale Hack, but does work.
instance (Rep a, Rep b) => Input (CSeq c a -> CSeq c b) where
	inPorts v =  (fn , v)
   	  where fn ~(Seq a ae) = deepSeq $ entity1 (Prim "hof") $ ae

	input _ a = a

-- Need to add the clock
instance (Rep a) => Input (HandShake (Seq a)) where
	inPorts v =  (fn , v)
	   -- We need the ~ because the output does not need to depend on the input
   	  where fn = HandShake $ \ ~(Seq _ ae) -> deepSeq $ entity1 (Prim "hof") $ ae
	input _ a = a


instance BackPorts (CSeq c a) where {}

instance Rep a => Ports (CSeq c a) where
  ports _ sig = wireCapture (seqDriver sig)

instance Rep a => Ports (Comb a) where
  ports _ sig = wireCapture (combDriver sig)

instance Rep a => Ports (HandShake (Seq a)) where
  ports vs (HandShake f) = ports vs f


instance (Ports a, Ports b) => Ports (a,b) where
  ports _ (a,b) = ports bad b ++
		  ports bad a
     where bad = error "bad using of arguments in Reify"

instance (Ports a, Ports b, Ports c) => Ports (a,b,c) where
  ports _ (a,b,c)
 		 = ports bad c ++
		   ports bad b ++
		   ports bad a
     where bad = error "bad using of arguments in Reify"

instance (Ports a,Size x) => Ports (Matrix x a) where
 ports _ m = concatMap (ports (error "bad using of arguments in Reify")) $ M.toList m

instance (Input a, Ports b) => Ports (a -> b) where
  ports vs f = ports vs' $ f a
     where (a,vs') = inPorts vs



--class OutPorts a where
--    outPorts :: a ->  [(Var, Type, Driver E)]


{-
input nm = liftS1 $ \ (Comb a d) ->
	let res  = Comb a $ D $ Port ("o0") $ E $ entity
	    entity = Entity (Name "Lava" "input")
                    [("o0", bitTypeOf res)]
                    [(nm, bitTypeOf res, unD d)]
		    []
	in res

-}

wireGenerate :: Int -> (D w,Int)
wireGenerate v = (D (Pad (OVar v ("i" ++ show v))),succ v)


instance Rep a => Input (CSeq c a) where
    inPorts vs = (Seq (error "Input (Seq a)") d,vs')
      where (d,vs') = wireGenerate vs

    getSignal ts = shallowSeq $ fromTrace ts
    apply m fn = (Map.deleteMin m, fn $ getSignal strm)
        where strm = head $ Map.elems m

    input nm = liftS1 (input nm)

instance Rep a => Input (Comb a) where
    inPorts vs = (deepComb d,vs')
      where (d,vs') = wireGenerate vs

    getSignal ts = shallowComb $ Stream.head $ fromTrace ts
    apply m fn = (Map.deleteMin m, fn $ getSignal strm)
        where strm = head $ Map.elems m

    input nm a = label nm a
{-
(Comb a d) =
	let res  = Comb a $ D $ Port ("o0") $ E $ entity
	    entity = Entity (Name "Lava" "input")
                    [("o0", bitTypeOf res)]
                    [(nm, bitTypeOf res, unD d)]
		    []
	in res
-}

{-

instance Input (Env clk) where
  inPorts nms = (Env (
-}

instance Input (Clock clk) where
    inPorts vs = (Clock (error "Input (Clock clk)") d,vs')
      where (d,vs') = wireGenerate vs

    input nm (Clock f d) =
	let res  = Clock f $ D $ Port ("o0") $ E $ entity
	    entity = Entity (Label "clk")
                    [("o0", ClkTy)]
                    [(nm, ClkTy, unD d)]
		    []
	in res

instance Input (Env clk) where
    inPorts vs0 = (Env clk' (label "rst" rst) (label "clk_en" en),vs3)
	 where ((en,rst,Clock f clk),vs3) = inPorts vs0
	       clk' = Clock f $ D $ Port ("o0") $ E
		    $ Entity (Label "clk")
                    	[("o0", ClkTy)]
                    	[("i0", ClkTy, unD clk)]
		    	[]

    getSignal ts = (toEnv (Clock 1 (D $ Error "no deep clock"))) { resetEnv = rst, enableEnv = clk_en }
        where (rst, clk_en) = unpack (shallowSeq $ fromTrace ts :: CSeq a (Bool, Bool))

    input nm (Env clk rst en) = Env (input ("clk" ++ nm) clk)
			            (input ("rst" ++ nm) rst)
			            (input ("sysEnable" ++ nm) en)	-- TODO: better name than sysEnable, its really clk_en

instance (Input a, Input b) => Input (a,b) where
    inPorts vs0 = ((a,b),vs2)
	 where
		(b,vs1) = inPorts vs0
		(a,vs2) = inPorts vs1

    apply m fn = (m', fn (getSignal s1, getSignal s2))
        where [s1,s2] = take 2 $ Map.elems m
              m' = Map.deleteMin $ Map.deleteMin m

    input nm (a,b) = (input (nm ++ "_fst") a,input (nm ++ "_snd") b)

instance (Input a, Size x) => Input (Matrix x a) where
 inPorts vs0 = (M.matrix bs, vsX)
     where
	sz :: Int
	sz = size (error "sz" :: x)

	loop vs0 0 = ([], vs0)
	loop vs0 n = (b:bs,vs2)
	   where (b, vs1) = inPorts vs0
		 (bs,vs2) = loop vs1 (n-1)

	bs :: [a]
	(bs,vsX) = loop vs0 sz

 input nm m = forEach m $ \ i a -> input (nm ++ "_" ++ show i) a

instance (Input a, Input b, Input c) => Input (a,b,c) where
    inPorts vs0 = ((a,b,c),vs3)
	 where
		(c,vs1) = inPorts vs0
		(b,vs2) = inPorts vs1
		(a,vs3) = inPorts vs2

    apply m fn = (m', fn (getSignal s1, getSignal s2, getSignal s3))
        where [s1,s2,s3] = take 3 $ Map.elems m
              m' = Map.deleteMin $ Map.deleteMin $ Map.deleteMin m

    input nm (a,b,c) = (input (nm ++ "_fst") a,input (nm ++ "_snd") b,input (nm ++ "_thd") c)

---------------------------------------
{-
showOptCircuit :: (Ports circuit) => [CircuitOptions] -> circuit -> IO String
showOptCircuit opt c = do
	rCir <- reifyCircuit opt c
	let loop n cs@((nm,Opt c _):_) | and [ n == 0 | (_,Opt c n) <- take 3 cs ] = do
		 putStrLn $ "## Answer " ++ show n ++ " ##############################"
		 print c
		 return c
	    loop n ((nm,Opt c v):cs) = do
		print $ "Round " ++ show n ++ " (" ++ show v ++ " " ++ nm ++ ")"
		print c
		loop (succ n) cs

	let opts = cycle [ ("opt",optimizeCircuit)
		       	 , ("copy",copyElimCircuit)
			 , ("dce",dceCircuit)
			 ]

	rCir' <- loop 0 (("init",Opt rCir 0) : optimizeCircuits opts rCir)
	return $ show rCir'
-}

-------------------------------------------------------------


output :: (Signal seq, Rep a)  => String -> seq a -> seq a
output nm = label nm

resolveNames :: Circuit -> Circuit
resolveNames cir
	| error1 = error $ "The generated input/output names are non distinct: " ++
			   show (map fst (theSrcs cir))
	| error3 = error "The labled input/output names are non distinct"
	| otherwise = Circuit { theCircuit = newCircuit
			 	     , theSrcs = newSrcs
				     , theSinks = newSinks
		           	     }
  where
	error1 = L.length (map fst (theSrcs cir)) /= L.length (nub (map fst (theSrcs cir)))
	error2 =  [ v
			| (_,e) <- newCircuit
			, v <- case e of
			    Entity _ _ ins _ -> [ nm | (_,_,Pad nm) <- ins ]
			, v `elem` oldSrcs
			]
	error3 = L.length (map fst newSrcs) /= L.length (nub (map fst newSrcs))

	newCircuit =
		[ ( u
		  , case e of
		      Entity nm outs ins misc ->
			Entity nm outs [ (n,t,fnInputs p) | (n,t,p) <- ins ] misc
--		      Entity (Name "Lava" "input") outs [(oNm,oTy,Pad (OVar i _))] misc
--			-> Entity (Name "Lava" "id") outs [(oNm,oTy,Pad (OVar i oNm))] misc
--		      Entity (Name "Lava" io) outs ins misc
--			| io `elem` ["input","output"]
--			-> Entity (Name "Lava" "id") outs ins misc
		      other -> other
		   )
		| (u,e) <- theCircuit cir
		]

	newSrcs :: [(OVar,Type)]
	newSrcs = [ case lookup nm mapInputs of
		       Nothing -> (nm,ty)
		       Just nm' -> (nm',ty)
	          | (nm,ty) <- theSrcs cir
		  ]

	-- Names that have been replaced.
	oldSrcs = [ nm
		  | (nm,ty) <- theSrcs cir
		  , not (nm `elem` (map fst newSrcs))
		  ]

	newSinks :: [(OVar,Type,Driver Unique)]
	newSinks = [ case dr of
		      Port _ u ->
			case lookup u (theCircuit cir) of
			  Just (Entity (Label nm') _ _ _) -> (OVar i nm',ty,dr)
		          _ -> (nm,ty,dr)
		      _ -> (nm,ty,dr)
		   | (nm@(OVar i _),ty,dr) <- theSinks cir
		   ]

	isOutput u = case lookup u (theCircuit cir) of
			Just (Entity (Name "Lava" "output") _ _ _) -> True
			_ -> False

	fnInputs :: Driver Unique -> Driver Unique
	fnInputs (Pad p) = Pad $ case lookup p mapInputs of
			     Nothing -> p
			     Just p' -> p'
	fnInputs other = other

	mapInputs :: [(OVar,OVar)]
	mapInputs = [ (OVar i inp,OVar i nm)
		    | (_,Entity (Label nm) _ [(_,_,Pad (OVar i inp))] _) <- theCircuit cir
		    ]


