%
% (c) The AQUA Project, Glasgow University, 1994-1996
%

\section[ArrBase]{Module @ArrBase@}

\begin{code}
{-# OPTIONS -fno-implicit-prelude #-}

module  ArrBase where

import {#- SOURCE #-}	IOBase	( error )
import Ix
import PrelList
import STBase
import PrelBase
import GHC

infixl 9  !, //
\end{code}

\begin{code}
{-# GENERATE_SPECS array a{~,Int,IPr} b{} #-}
array		      :: (Ix a) => (a,a) -> [(a,b)] -> Array a b

{-# GENERATE_SPECS (!) a{~,Int,IPr} b{} #-}
(!)		      :: (Ix a) => Array a b -> a -> b

bounds		      :: (Ix a) => Array a b -> (a,a)

{-# GENERATE_SPECS (//) a{~,Int,IPr} b{} #-}
(//)		      :: (Ix a) => Array a b -> [(a,b)] -> Array a b

{-# GENERATE_SPECS accum a{~,Int,IPr} b{} c{} #-}
accum		      :: (Ix a) => (b -> c -> b) -> Array a b -> [(a,c)] -> Array a b

{-# GENERATE_SPECS accumArray a{~,Int,IPr} b{} c{} #-}
accumArray	      :: (Ix a) => (b -> c -> b) -> b -> (a,a) -> [(a,c)] -> Array a b
\end{code}


%*********************************************************
%*							*
\subsection{The @Array@ types}
%*							*
%*********************************************************

\begin{code}
type IPr = (Int, Int)

data Ix ix => Array ix elt		= Array     	   (ix,ix) (Array# elt)
data Ix ix => ByteArray ix      	= ByteArray	   (ix,ix) ByteArray#
data Ix ix => MutableArray     s ix elt = MutableArray     (ix,ix) (MutableArray# s elt)
data Ix ix => MutableByteArray s ix     = MutableByteArray (ix,ix) (MutableByteArray# s)
\end{code}


%*********************************************************
%*							*
\subsection{Operations on immutable arrays}
%*							*
%*********************************************************

"array", "!" and "bounds" are basic; the rest can be defined in terms of them

\begin{code}
bounds (Array b _)  = b

(Array bounds arr#) ! i
  = let n# = case (index bounds i) of { I# x -> x } -- index fails if out of range
    in
    case (indexArray# arr# n#) of
      Lift v -> v

#ifdef USE_FOLDR_BUILD
{-# INLINE array #-}
#endif
array ixs@(ix_start, ix_end) ivs =
   runST ( ST $ \ s ->
	case (newArray ixs arrEleBottom)	of { ST new_array_thing ->
	case (new_array_thing s)		of { (arr@(MutableArray _ arr#),s) ->
	let
         fill_one_in (S# s#) (i, v)
             = case index ixs  i		of { I# n# ->
	       case writeArray# arr# n# v s# 	of { s2#   ->
	       S# s2# }}
	in
	case (foldl fill_one_in s ivs) 		of { s@(S# _) -> 
	case (freezeArray arr)			of { ST freeze_array_thing ->
	freeze_array_thing s }}}})

arrEleBottom = error "(Array.!): undefined array element"

fill_it_in :: Ix ix => MutableArray s ix elt -> [(ix, elt)] -> ST s ()
fill_it_in arr lst
  = foldr fill_one_in (returnStrictlyST ()) lst
  where  -- **** STRICT **** (but that's OK...)
    fill_one_in (i, v) rst
      = writeArray arr i v `seqStrictlyST` rst

-----------------------------------------------------------------------
-- these also go better with magic: (//), accum, accumArray

old_array // ivs
  = runST (
	-- copy the old array:
	thawArray old_array		    `thenStrictlyST` \ arr ->	
	-- now write the new elements into the new array:
	fill_it_in arr ivs		    `seqStrictlyST`
	freezeArray arr
    )
  where
    bottom = error "(Array.//): error in copying old array\n"

zap_with_f :: Ix ix => (elt -> elt2 -> elt) -> MutableArray s ix elt -> [(ix,elt2)] -> ST s ()
-- zap_with_f: reads an elem out first, then uses "f" on that and the new value

zap_with_f f arr lst
  = foldr zap_one (returnStrictlyST ()) lst
  where
    zap_one (i, new_v) rst
      = readArray  arr i		 `thenStrictlyST`  \ old_v ->
	writeArray arr i (f old_v new_v) `seqStrictlyST`
	rst

accum f old_array ivs
  = runST (
	-- copy the old array:
	thawArray old_array		    `thenStrictlyST` \ arr ->	

	-- now zap the elements in question with "f":
	zap_with_f f arr ivs		>>
	freezeArray arr
    )
  where
    bottom = error "Array.accum: error in copying old array\n"

accumArray f zero ixs ivs
  = runST (
	newArray ixs zero	>>= \ arr# ->
	zap_with_f f  arr# ivs	>>
	freezeArray arr#
    )
\end{code}


%*********************************************************
%*							*
\subsection{Operations on mutable arrays}
%*							*
%*********************************************************

Idle ADR question: What's the tradeoff here between flattening these
datatypes into @MutableArray ix ix (MutableArray# s elt)@ and using
it as is?  As I see it, the former uses slightly less heap and
provides faster access to the individual parts of the bounds while the
code used has the benefit of providing a ready-made @(lo, hi)@ pair as
required by many array-related functions.  Which wins? Is the
difference significant (probably not).

Idle AJG answer: When I looked at the outputted code (though it was 2
years ago) it seems like you often needed the tuple, and we build
it frequently. Now we've got the overloading specialiser things
might be different, though.

\begin{code}
newArray :: Ix ix => (ix,ix) -> elt -> ST s (MutableArray s ix elt)
newCharArray, newIntArray, newAddrArray, newFloatArray, newDoubleArray
	 :: Ix ix => (ix,ix) -> ST s (MutableByteArray s ix) 

{-# SPECIALIZE newArray      :: IPr       -> elt -> ST s (MutableArray s Int elt),
				(IPr,IPr) -> elt -> ST s (MutableArray s IPr elt)
  #-}
{-# SPECIALIZE newCharArray   :: IPr -> ST s (MutableByteArray s Int) #-}
{-# SPECIALIZE newIntArray    :: IPr -> ST s (MutableByteArray s Int) #-}
{-# SPECIALIZE newAddrArray   :: IPr -> ST s (MutableByteArray s Int) #-}
{-# SPECIALIZE newFloatArray  :: IPr -> ST s (MutableByteArray s Int) #-}
{-# SPECIALIZE newDoubleArray :: IPr -> ST s (MutableByteArray s Int) #-}

newArray ixs@(ix_start, ix_end) init = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else (index ixs ix_end) + 1) of { I# x -> x }
	-- size is one bigger than index of last elem
    in
    case (newArray# n# init s#)     of { StateAndMutableArray# s2# arr# ->
    (MutableArray ixs arr#, S# s2#)}

newCharArray ixs@(ix_start, ix_end) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case (newCharArray# n# s#)	  of { StateAndMutableByteArray# s2# barr# ->
    (MutableByteArray ixs barr#, S# s2#)}

newIntArray ixs@(ix_start, ix_end) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case (newIntArray# n# s#)	  of { StateAndMutableByteArray# s2# barr# ->
    (MutableByteArray ixs barr#, S# s2#)}

newAddrArray ixs@(ix_start, ix_end) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case (newAddrArray# n# s#)	  of { StateAndMutableByteArray# s2# barr# ->
    (MutableByteArray ixs barr#, S# s2#)}

newFloatArray ixs@(ix_start, ix_end) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case (newFloatArray# n# s#)	  of { StateAndMutableByteArray# s2# barr# ->
    (MutableByteArray ixs barr#, S# s2#)}

newDoubleArray ixs@(ix_start, ix_end) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case (newDoubleArray# n# s#)  of { StateAndMutableByteArray# s2# barr# ->
    (MutableByteArray ixs barr#, S# s2#)}

boundsOfArray     :: Ix ix => MutableArray s ix elt -> (ix, ix)  
boundsOfByteArray :: Ix ix => MutableByteArray s ix -> (ix, ix)

{-# SPECIALIZE boundsOfArray     :: MutableArray s Int elt -> IPr #-}
{-# SPECIALIZE boundsOfByteArray :: MutableByteArray s Int -> IPr #-}

boundsOfArray     (MutableArray     ixs _) = ixs
boundsOfByteArray (MutableByteArray ixs _) = ixs

readArray   	:: Ix ix => MutableArray s ix elt -> ix -> ST s elt 

readCharArray   :: Ix ix => MutableByteArray s ix -> ix -> ST s Char 
readIntArray    :: Ix ix => MutableByteArray s ix -> ix -> ST s Int
readAddrArray   :: Ix ix => MutableByteArray s ix -> ix -> ST s Addr
readFloatArray  :: Ix ix => MutableByteArray s ix -> ix -> ST s Float
readDoubleArray :: Ix ix => MutableByteArray s ix -> ix -> ST s Double

{-# SPECIALIZE readArray       :: MutableArray s Int elt -> Int -> ST s elt,
				  MutableArray s IPr elt -> IPr -> ST s elt
  #-}
{-# SPECIALIZE readCharArray   :: MutableByteArray s Int -> Int -> ST s Char #-}
{-# SPECIALIZE readIntArray    :: MutableByteArray s Int -> Int -> ST s Int #-}
{-# SPECIALIZE readAddrArray   :: MutableByteArray s Int -> Int -> ST s Addr #-}
--NO:{-# SPECIALIZE readFloatArray  :: MutableByteArray s Int -> Int -> ST s Float #-}
{-# SPECIALIZE readDoubleArray :: MutableByteArray s Int -> Int -> ST s Double #-}

readArray (MutableArray ixs arr#) n = ST $ \ (S# s#) ->
    case (index ixs n)	    	of { I# n# ->
    case readArray# arr# n# s#	of { StateAndPtr# s2# r ->
    (r, S# s2#)}}

readCharArray (MutableByteArray ixs barr#) n = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	of { I# n# ->
    case readCharArray# barr# n# s#	of { StateAndChar# s2# r# ->
    (C# r#, S# s2#)}}

readIntArray (MutableByteArray ixs barr#) n = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	of { I# n# ->
    case readIntArray# barr# n# s#	of { StateAndInt# s2# r# ->
    (I# r#, S# s2#)}}

readAddrArray (MutableByteArray ixs barr#) n = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	of { I# n# ->
    case readAddrArray# barr# n# s#	of { StateAndAddr# s2# r# ->
    (A# r#, S# s2#)}}

readFloatArray (MutableByteArray ixs barr#) n = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	of { I# n# ->
    case readFloatArray# barr# n# s#	of { StateAndFloat# s2# r# ->
    (F# r#, S# s2#)}}

readDoubleArray (MutableByteArray ixs barr#) n = ST $ \ (S# s#) ->
    case (index ixs n) 	    	    	of { I# n# ->
    case readDoubleArray# barr# n# s#	of { StateAndDouble# s2# r# ->
    (D# r#, S# s2#)}}

--Indexing of ordinary @Arrays@ is standard Haskell and isn't defined here.
indexCharArray   :: Ix ix => ByteArray ix -> ix -> Char 
indexIntArray    :: Ix ix => ByteArray ix -> ix -> Int
indexAddrArray   :: Ix ix => ByteArray ix -> ix -> Addr
indexFloatArray  :: Ix ix => ByteArray ix -> ix -> Float
indexDoubleArray :: Ix ix => ByteArray ix -> ix -> Double

{-# SPECIALIZE indexCharArray   :: ByteArray Int -> Int -> Char #-}
{-# SPECIALIZE indexIntArray    :: ByteArray Int -> Int -> Int #-}
{-# SPECIALIZE indexAddrArray   :: ByteArray Int -> Int -> Addr #-}
--NO:{-# SPECIALIZE indexFloatArray  :: ByteArray Int -> Int -> Float #-}
{-# SPECIALIZE indexDoubleArray :: ByteArray Int -> Int -> Double #-}

indexCharArray (ByteArray ixs barr#) n
  = case (index ixs n)	    	    	of { I# n# ->
    case indexCharArray# barr# n# 	of { r# ->
    (C# r#)}}

indexIntArray (ByteArray ixs barr#) n
  = case (index ixs n)	    	    	of { I# n# ->
    case indexIntArray# barr# n# 	of { r# ->
    (I# r#)}}

indexAddrArray (ByteArray ixs barr#) n
  = case (index ixs n)	    	    	of { I# n# ->
    case indexAddrArray# barr# n# 	of { r# ->
    (A# r#)}}

indexFloatArray (ByteArray ixs barr#) n
  = case (index ixs n)	    	    	of { I# n# ->
    case indexFloatArray# barr# n# 	of { r# ->
    (F# r#)}}

indexDoubleArray (ByteArray ixs barr#) n
  = case (index ixs n) 	    	    	of { I# n# ->
    case indexDoubleArray# barr# n# 	of { r# ->
    (D# r#)}}

--Indexing off @Addrs@ is similar, and therefore given here.
indexCharOffAddr   :: Addr -> Int -> Char
indexIntOffAddr    :: Addr -> Int -> Int
indexAddrOffAddr   :: Addr -> Int -> Addr
indexFloatOffAddr  :: Addr -> Int -> Float
indexDoubleOffAddr :: Addr -> Int -> Double

indexCharOffAddr (A# addr#) n
  = case n  	    		    	of { I# n# ->
    case indexCharOffAddr# addr# n# 	of { r# ->
    (C# r#)}}

indexIntOffAddr (A# addr#) n
  = case n  	    		    	of { I# n# ->
    case indexIntOffAddr# addr# n# 	of { r# ->
    (I# r#)}}

indexAddrOffAddr (A# addr#) n
  = case n  	    	    	    	of { I# n# ->
    case indexAddrOffAddr# addr# n# 	of { r# ->
    (A# r#)}}

indexFloatOffAddr (A# addr#) n
  = case n  	    		    	of { I# n# ->
    case indexFloatOffAddr# addr# n# 	of { r# ->
    (F# r#)}}

indexDoubleOffAddr (A# addr#) n
  = case n  	    	 	    	of { I# n# ->
    case indexDoubleOffAddr# addr# n# 	of { r# ->
    (D# r#)}}

writeArray  	 :: Ix ix => MutableArray s ix elt -> ix -> elt -> ST s () 
writeCharArray   :: Ix ix => MutableByteArray s ix -> ix -> Char -> ST s () 
writeIntArray    :: Ix ix => MutableByteArray s ix -> ix -> Int  -> ST s () 
writeAddrArray   :: Ix ix => MutableByteArray s ix -> ix -> Addr -> ST s () 
writeFloatArray  :: Ix ix => MutableByteArray s ix -> ix -> Float -> ST s () 
writeDoubleArray :: Ix ix => MutableByteArray s ix -> ix -> Double -> ST s () 

{-# SPECIALIZE writeArray  	:: MutableArray s Int elt -> Int -> elt -> ST s (),
				   MutableArray s IPr elt -> IPr -> elt -> ST s ()
  #-}
{-# SPECIALIZE writeCharArray   :: MutableByteArray s Int -> Int -> Char -> ST s () #-}
{-# SPECIALIZE writeIntArray    :: MutableByteArray s Int -> Int -> Int  -> ST s () #-}
{-# SPECIALIZE writeAddrArray   :: MutableByteArray s Int -> Int -> Addr -> ST s () #-}
--NO:{-# SPECIALIZE writeFloatArray  :: MutableByteArray s Int -> Int -> Float -> ST s () #-}
{-# SPECIALIZE writeDoubleArray :: MutableByteArray s Int -> Int -> Double -> ST s () #-}

writeArray (MutableArray ixs arr#) n ele = ST $ \ (S# s#) ->
    case index ixs n		    of { I# n# ->
    case writeArray# arr# n# ele s# of { s2# ->
    ((), S# s2#)}}

writeCharArray (MutableByteArray ixs barr#) n (C# ele) = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	    of { I# n# ->
    case writeCharArray# barr# n# ele s#    of { s2#   ->
    ((), S# s2#)}}

writeIntArray (MutableByteArray ixs barr#) n (I# ele) = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	    of { I# n# ->
    case writeIntArray# barr# n# ele s#     of { s2#   ->
    ((), S# s2#)}}

writeAddrArray (MutableByteArray ixs barr#) n (A# ele) = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	    of { I# n# ->
    case writeAddrArray# barr# n# ele s#    of { s2#   ->
    ((), S# s2#)}}

writeFloatArray (MutableByteArray ixs barr#) n (F# ele) = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	    of { I# n# ->
    case writeFloatArray# barr# n# ele s#   of { s2#   ->
    ((), S# s2#)}}

writeDoubleArray (MutableByteArray ixs barr#) n (D# ele) = ST $ \ (S# s#) ->
    case (index ixs n)	    	    	    of { I# n# ->
    case writeDoubleArray# barr# n# ele s#  of { s2#   ->
    ((), S# s2#)}}
\end{code}


%*********************************************************
%*							*
\subsection{Moving between mutable and immutable}
%*							*
%*********************************************************

\begin{code}
freezeArray	  :: Ix ix => MutableArray s ix elt -> ST s (Array ix elt)
freezeCharArray   :: Ix ix => MutableByteArray s ix -> ST s (ByteArray ix)
freezeIntArray    :: Ix ix => MutableByteArray s ix -> ST s (ByteArray ix)
freezeAddrArray   :: Ix ix => MutableByteArray s ix -> ST s (ByteArray ix)
freezeFloatArray  :: Ix ix => MutableByteArray s ix -> ST s (ByteArray ix)
freezeDoubleArray :: Ix ix => MutableByteArray s ix -> ST s (ByteArray ix)

{-# SPECIALISE freezeArray :: MutableArray s Int elt -> ST s (Array Int elt),
			      MutableArray s IPr elt -> ST s (Array IPr elt)
  #-}
{-# SPECIALISE freezeCharArray :: MutableByteArray s Int -> ST s (ByteArray Int) #-}

freezeArray (MutableArray ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else (index ixs ix_end) + 1) of { I# x -> x }
    in
    case freeze arr# n# s# of { StateAndArray# s2# frozen# ->
    (Array ixs frozen#, S# s2#)}
  where
    freeze  :: MutableArray# s ele	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> StateAndArray# s ele

    freeze arr# n# s#
      = case newArray# n# init s#	      of { StateAndMutableArray# s2# newarr1# ->
	case copy 0# n# arr# newarr1# s2#     of { StateAndMutableArray# s3# newarr2# ->
	unsafeFreezeArray# newarr2# s3#
	}}
      where
	init = error "freezeArray: element not copied"

	copy :: Int# -> Int#
	     -> MutableArray# s ele -> MutableArray# s ele
	     -> State# s
	     -> StateAndMutableArray# s ele

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableArray# s# to#
	  | True
	    = case readArray#  from# cur#     s#  of { StateAndPtr# s1# ele ->
	      case writeArray# to#   cur# ele s1# of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

freezeCharArray (MutableByteArray ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case freeze arr# n# s# of { StateAndByteArray# s2# frozen# ->
    (ByteArray ixs frozen#, S# s2#) }
  where
    freeze  :: MutableByteArray# s	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> StateAndByteArray# s

    freeze arr# n# s#
      = case (newCharArray# n# s#)    	   of { StateAndMutableByteArray# s2# newarr1# ->
	case copy 0# n# arr# newarr1# s2#  of { StateAndMutableByteArray# s3# newarr2# ->
	unsafeFreezeByteArray# newarr2# s3#
	}}
      where
	copy :: Int# -> Int#
	     -> MutableByteArray# s -> MutableByteArray# s
	     -> State# s
	     -> StateAndMutableByteArray# s

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableByteArray# s# to#
	  | True
	    = case (readCharArray#  from# cur#     s#)  of { StateAndChar# s1# ele ->
	      case (writeCharArray# to#   cur# ele s1#) of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

freezeIntArray (MutableByteArray ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case freeze arr# n# s# of { StateAndByteArray# s2# frozen# ->
    (ByteArray ixs frozen#, S# s2#) }
  where
    freeze  :: MutableByteArray# s	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> StateAndByteArray# s

    freeze arr# n# s#
      = case (newIntArray# n# s#)    	   of { StateAndMutableByteArray# s2# newarr1# ->
	case copy 0# n# arr# newarr1# s2#  of { StateAndMutableByteArray# s3# newarr2# ->
	unsafeFreezeByteArray# newarr2# s3#
	}}
      where
	copy :: Int# -> Int#
	     -> MutableByteArray# s -> MutableByteArray# s
	     -> State# s
	     -> StateAndMutableByteArray# s

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableByteArray# s# to#
	  | True
	    = case (readIntArray#  from# cur#     s#)  of { StateAndInt# s1# ele ->
	      case (writeIntArray# to#   cur# ele s1#) of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

freezeAddrArray (MutableByteArray ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case freeze arr# n# s# of { StateAndByteArray# s2# frozen# ->
    (ByteArray ixs frozen#, S# s2#) }
  where
    freeze  :: MutableByteArray# s	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> StateAndByteArray# s

    freeze arr# n# s#
      = case (newAddrArray# n# s#)    	   of { StateAndMutableByteArray# s2# newarr1# ->
	case copy 0# n# arr# newarr1# s2#  of { StateAndMutableByteArray# s3# newarr2# ->
	unsafeFreezeByteArray# newarr2# s3#
	}}
      where
	copy :: Int# -> Int#
	     -> MutableByteArray# s -> MutableByteArray# s
	     -> State# s
	     -> StateAndMutableByteArray# s

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableByteArray# s# to#
	  | True
	    = case (readAddrArray#  from# cur#     s#)  of { StateAndAddr# s1# ele ->
	      case (writeAddrArray# to#   cur# ele s1#) of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

freezeFloatArray (MutableByteArray ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case freeze arr# n# s# of { StateAndByteArray# s2# frozen# ->
    (ByteArray ixs frozen#, S# s2#) }
  where
    freeze  :: MutableByteArray# s	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> StateAndByteArray# s

    freeze arr# n# s#
      = case (newFloatArray# n# s#)    	   of { StateAndMutableByteArray# s2# newarr1# ->
	case copy 0# n# arr# newarr1# s2#  of { StateAndMutableByteArray# s3# newarr2# ->
	unsafeFreezeByteArray# newarr2# s3#
	}}
      where
	copy :: Int# -> Int#
	     -> MutableByteArray# s -> MutableByteArray# s
	     -> State# s
	     -> StateAndMutableByteArray# s

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableByteArray# s# to#
	  | True
	    = case (readFloatArray#  from# cur#     s#)  of { StateAndFloat# s1# ele ->
	      case (writeFloatArray# to#   cur# ele s1#) of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

freezeDoubleArray (MutableByteArray ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else ((index ixs ix_end) + 1)) of { I# x -> x }
    in
    case freeze arr# n# s# of { StateAndByteArray# s2# frozen# ->
    (ByteArray ixs frozen#, S# s2#) }
  where
    freeze  :: MutableByteArray# s	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> StateAndByteArray# s

    freeze arr# n# s#
      = case (newDoubleArray# n# s#)   	   of { StateAndMutableByteArray# s2# newarr1# ->
	case copy 0# n# arr# newarr1# s2#  of { StateAndMutableByteArray# s3# newarr2# ->
	unsafeFreezeByteArray# newarr2# s3#
	}}
      where
	copy :: Int# -> Int#
	     -> MutableByteArray# s -> MutableByteArray# s
	     -> State# s
	     -> StateAndMutableByteArray# s

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableByteArray# s# to#
	  | True
	    = case (readDoubleArray#  from# cur#     s#)  of { StateAndDouble# s1# ele ->
	      case (writeDoubleArray# to#   cur# ele s1#) of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

unsafeFreezeArray     :: Ix ix => MutableArray s ix elt -> ST s (Array ix elt)  
unsafeFreezeByteArray :: Ix ix => MutableByteArray s ix -> ST s (ByteArray ix)

{-# SPECIALIZE unsafeFreezeByteArray :: MutableByteArray s Int -> ST s (ByteArray Int)
  #-}

unsafeFreezeArray (MutableArray ixs arr#) = ST $ \ (S# s#) ->
    case unsafeFreezeArray# arr# s# of { StateAndArray# s2# frozen# ->
    (Array ixs frozen#, S# s2#) }

unsafeFreezeByteArray (MutableByteArray ixs arr#) = ST $ \ (S# s#) ->
    case unsafeFreezeByteArray# arr# s# of { StateAndByteArray# s2# frozen# ->
    (ByteArray ixs frozen#, S# s2#) }


--This takes a immutable array, and copies it into a mutable array, in a
--hurry.

{-# SPECIALISE thawArray :: Array Int elt -> ST s (MutableArray s Int elt),
			    Array IPr elt -> ST s (MutableArray s IPr elt)
  #-}

thawArray :: Ix ix => Array ix elt -> ST s (MutableArray s ix elt)
thawArray (Array ixs@(ix_start, ix_end) arr#) = ST $ \ (S# s#) ->
    let n# = case (if null (range ixs)
		  then 0
		  else (index ixs ix_end) + 1) of { I# x -> x }
    in
    case thaw arr# n# s# of { StateAndMutableArray# s2# thawed# ->
    (MutableArray ixs thawed#, S# s2#)}
  where
    thaw  :: Array# ele			-- the thing
	    -> Int#			-- size of thing to be thawed
	    -> State# s			-- the Universe and everything
	    -> StateAndMutableArray# s ele

    thaw arr# n# s#
      = case newArray# n# init s#	      of { StateAndMutableArray# s2# newarr1# ->
	copy 0# n# arr# newarr1# s2# }
      where
	init = error "thawArray: element not copied"

	copy :: Int# -> Int#
	     -> Array# ele 
	     -> MutableArray# s ele
	     -> State# s
	     -> StateAndMutableArray# s ele

	copy cur# end# from# to# s#
	  | cur# ==# end#
	    = StateAndMutableArray# s# to#
	  | True
	    = case indexArray#  from# cur#       of { Lift ele ->
	      case writeArray# to#   cur# ele s# of { s1# ->
	      copy (cur# +# 1#) end# from# to# s1#
	      }}
\end{code}

%*********************************************************
%*							*
\subsection{Ghastly return types}
%*							*
%*********************************************************

\begin{code}
data StateAndArray#            s elt = StateAndArray#        (State# s) (Array# elt) 
data StateAndMutableArray#     s elt = StateAndMutableArray# (State# s) (MutableArray# s elt)
data StateAndByteArray#        s = StateAndByteArray#        (State# s) ByteArray# 
data StateAndMutableByteArray# s = StateAndMutableByteArray# (State# s) (MutableByteArray# s)
\end{code}
