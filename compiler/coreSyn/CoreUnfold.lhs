%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1994-1998
%

Core-syntax unfoldings

Unfoldings (which can travel across module boundaries) are in Core
syntax (namely @CoreExpr@s).

The type @Unfolding@ sits ``above'' simply-Core-expressions
unfoldings, capturing ``higher-level'' things we know about a binding,
usually things that the simplifier found out (e.g., ``it's a
literal'').  In the corner of a @CoreUnfolding@ unfolding, you will
find, unsurprisingly, a Core expression.

\begin{code}
module CoreUnfold (
	Unfolding, UnfoldingGuidance,	-- Abstract types

	noUnfolding, mkImplicitUnfolding, 
	mkTopUnfolding, mkUnfolding, 
	mkInlineRule, mkWwInlineRule,
	mkCompulsoryUnfolding, 

	couldBeSmallEnoughToInline, 
	certainlyWillInline, smallEnoughToInline,

	callSiteInline, CallCtxt(..)

    ) where

import StaticFlags
import DynFlags
import CoreSyn
import PprCore		()	-- Instances
import OccurAnal
import CoreSubst 	( emptySubst, substTy, extendIdSubst, extendTvSubst
			, lookupIdSubst, substBndr, substBndrs, substRecBndrs )
import CoreUtils
import Id
import DataCon
import Literal
import PrimOp
import IdInfo
import BasicTypes	( Arity )
import Type hiding( substTy, extendTvSubst )
import Maybes
import PrelNames
import Bag
import FastTypes
import FastString
import Outputable

\end{code}


%************************************************************************
%*									*
\subsection{Making unfoldings}
%*									*
%************************************************************************

\begin{code}
mkTopUnfolding :: CoreExpr -> Unfolding
mkTopUnfolding expr = mkUnfolding True {- Top level -} expr

mkImplicitUnfolding :: CoreExpr -> Unfolding
-- For implicit Ids, do a tiny bit of optimising first
mkImplicitUnfolding expr 
  = CoreUnfolding (simpleOptExpr expr)
		  True
		  (exprIsHNF expr)
		  (exprIsCheap expr)
		  (calcUnfoldingGuidance opt_UF_CreationThreshold expr)

mkInlineRule :: CoreExpr -> Arity -> Unfolding
mkInlineRule expr arity 
  = InlineRule { uf_tmpl = simpleOptExpr expr, 
    	         uf_is_top = True, 	 -- Conservative; this gets set more
		 	     		 -- accuately by the simplifier (slight hack)
					 -- in SimplEnv.substUnfolding
                 uf_arity = arity, 
		 uf_is_value = exprIsHNF expr,
		 uf_worker = Nothing }

mkWwInlineRule :: CoreExpr -> Arity -> Id -> Unfolding
mkWwInlineRule expr arity wkr 
  = InlineRule { uf_tmpl = simpleOptExpr expr, 
    	         uf_is_top = True, 	 -- Conservative; see mkInlineRule
                 uf_arity = arity, 
		 uf_is_value = exprIsHNF expr,
		 uf_worker = Just wkr }

mkUnfolding :: Bool -> CoreExpr -> Unfolding
mkUnfolding top_lvl expr
  = CoreUnfolding { uf_tmpl = occurAnalyseExpr expr,
		    uf_is_top = top_lvl,
		    uf_is_value = exprIsHNF expr,
		    uf_is_cheap = exprIsCheap expr,
		    uf_guidance = calcUnfoldingGuidance opt_UF_CreationThreshold expr }
	-- Sometimes during simplification, there's a large let-bound thing	
	-- which has been substituted, and so is now dead; so 'expr' contains
	-- two copies of the thing while the occurrence-analysed expression doesn't
	-- Nevertheless, we don't occ-analyse before computing the size because the
	-- size computation bales out after a while, whereas occurrence analysis does not.
	--
	-- This can occasionally mean that the guidance is very pessimistic;
	-- it gets fixed up next round

mkCompulsoryUnfolding :: CoreExpr -> Unfolding
mkCompulsoryUnfolding expr	-- Used for things that absolutely must be unfolded
  = CompulsoryUnfolding (occurAnalyseExpr expr)
\end{code}


%************************************************************************
%*									*
\subsection{The UnfoldingGuidance type}
%*									*
%************************************************************************

\begin{code}
calcUnfoldingGuidance
	:: Int		    	-- bomb out if size gets bigger than this
	-> CoreExpr    		-- expression to look at
	-> UnfoldingGuidance
calcUnfoldingGuidance bOMB_OUT_SIZE expr
  = case collectBinders expr of { (binders, body) ->
    let
        val_binders = filter isId binders
	n_val_binders = length val_binders
    in
    case (sizeExpr (iUnbox bOMB_OUT_SIZE) val_binders body) of
      TooBig -> UnfoldNever
      SizeIs size cased_args scrut_discount
	-> UnfoldIfGoodArgs { ug_arity = n_val_binders
	   		    , ug_args  = map discount_for val_binders
			    , ug_size  = iBox size
			    , ug_res   = iBox scrut_discount }
	where        
	    discount_for b = foldlBag (\acc (b',n) -> if b==b' then acc+n else acc) 
				      0 cased_args
	}
\end{code}

\begin{code}
sizeExpr :: FastInt 	    -- Bomb out if it gets bigger than this
	 -> [Id]	    -- Arguments; we're interested in which of these
			    -- get case'd
	 -> CoreExpr
	 -> ExprSize

sizeExpr bOMB_OUT_SIZE top_args expr
  = size_up expr
  where
    size_up (Type _)           = sizeZero      -- Types cost nothing
    size_up (Var _)            = sizeOne
    size_up (Note _ body)      = size_up body  -- Notes cost nothing
    size_up (Cast e _)         = size_up e
    size_up (App fun (Type _)) = size_up fun
    size_up (App fun arg)      = size_up_app fun [arg]

    size_up (Lit lit) 	       = sizeN (litSize lit)

    size_up (Lam b e) | isId b    = lamScrutDiscount (size_up e `addSizeN` 1)
		      | otherwise = size_up e

    size_up (Let (NonRec binder rhs) body)
      = nukeScrutDiscount (size_up rhs)		`addSize`
	size_up body				`addSizeN`
	(if isUnLiftedType (idType binder) then 0 else 1)
		-- For the allocation
		-- If the binder has an unlifted type there is no allocation

    size_up (Let (Rec pairs) body)
      = nukeScrutDiscount rhs_size		`addSize`
	size_up body				`addSizeN`
	length pairs		-- For the allocation
      where
	rhs_size = foldr (addSize . size_up . snd) sizeZero pairs

    size_up (Case (Var v) _ _ alts) 
	| v `elem` top_args		-- We are scrutinising an argument variable
	= 
{-	I'm nuking this special case; BUT see the comment with case alternatives.

	(a) It's too eager.  We don't want to inline a wrapper into a
	    context with no benefit.  
	    E.g.  \ x. f (x+x)   	no point in inlining (+) here!

	(b) It's ineffective. Once g's wrapper is inlined, its case-expressions 
	    aren't scrutinising arguments any more

	    case alts of

		[alt] -> size_up_alt alt `addSize` SizeIs (_ILIT(0)) (unitBag (v, 1)) (_ILIT(0))
		-- We want to make wrapper-style evaluation look cheap, so that
		-- when we inline a wrapper it doesn't make call site (much) bigger
		-- Otherwise we get nasty phase ordering stuff: 
		--	f x = g x x
		--	h y = ...(f e)...
		-- If we inline g's wrapper, f looks big, and doesn't get inlined
		-- into h; if we inline f first, while it looks small, then g's 
		-- wrapper will get inlined later anyway.  To avoid this nasty
		-- ordering difference, we make (case a of (x,y) -> ...), 
		--  *where a is one of the arguments* look free.

		other -> 
-}
			 alts_size (foldr addSize sizeOne alt_sizes)	-- The 1 is for the scrutinee
				   (foldr1 maxSize alt_sizes)

		-- Good to inline if an arg is scrutinised, because
		-- that may eliminate allocation in the caller
		-- And it eliminates the case itself

	where
	  alt_sizes = map size_up_alt alts

		-- alts_size tries to compute a good discount for
		-- the case when we are scrutinising an argument variable
	  alts_size (SizeIs tot _tot_disc _tot_scrut)           -- Size of all alternatives
		    (SizeIs max  max_disc  max_scrut)           -- Size of biggest alternative
	 	= SizeIs tot (unitBag (v, iBox (_ILIT(1) +# tot -# max)) `unionBags` max_disc) max_scrut
			-- If the variable is known, we produce a discount that
			-- will take us back to 'max', the size of rh largest alternative
			-- The 1+ is a little discount for reduced allocation in the caller
	  alts_size tot_size _ = tot_size

    size_up (Case e _ _ alts) = nukeScrutDiscount (size_up e) `addSize` 
			         foldr (addSize . size_up_alt) sizeZero alts
	  	-- We don't charge for the case itself
		-- It's a strict thing, and the price of the call
		-- is paid by scrut.  Also consider
		--	case f x of DEFAULT -> e
		-- This is just ';'!  Don't charge for it.

    ------------ 
    size_up_app (App fun arg) args   
	| isTypeArg arg		     = size_up_app fun args
	| otherwise		     = size_up_app fun (arg:args)
    size_up_app fun 	      args   = foldr (addSize . nukeScrutDiscount . size_up) 
					     (size_up_fun fun args)
					     args

	-- A function application with at least one value argument
	-- so if the function is an argument give it an arg-discount
	--
	-- Also behave specially if the function is a build
	--
	-- Also if the function is a constant Id (constr or primop)
	-- compute discounts specially
    size_up_fun (Var fun) args
      | fun `hasKey` buildIdKey   = buildSize
      | fun `hasKey` augmentIdKey = augmentSize
      | otherwise 
      = case globalIdDetails fun of
	  DataConWorkId dc -> conSizeN dc (valArgCount args)

	  FCallId _    -> sizeN opt_UF_DearOp
	  PrimOpId op  -> primOpSize op (valArgCount args)
			  -- foldr addSize (primOpSize op) (map arg_discount args)
			  -- At one time I tried giving an arg-discount if a primop 
			  -- is applied to one of the function's arguments, but it's
			  -- not good.  At the moment, any unlifted-type arg gets a
			  -- 'True' for 'yes I'm evald', so we collect the discount even
			  -- if we know nothing about it.  And just having it in a primop
			  -- doesn't help at all if we don't know something more.

	  _            -> fun_discount fun `addSizeN`
			  (1 + length (filter (not . exprIsTrivial) args))
				-- The 1+ is for the function itself
				-- Add 1 for each non-trivial arg;
				-- the allocation cost, as in let(rec)
				-- Slight hack here: for constructors the args are almost always
				--	trivial; and for primops they are almost always prim typed
				-- 	We should really only count for non-prim-typed args in the
				--	general case, but that seems too much like hard work

    size_up_fun other _ = size_up other

    ------------ 
    size_up_alt (_con, _bndrs, rhs) = size_up rhs
 	-- Don't charge for args, so that wrappers look cheap
	-- (See comments about wrappers with Case)

    ------------
	-- We want to record if we're case'ing, or applying, an argument
    fun_discount v | v `elem` top_args = SizeIs (_ILIT(0)) (unitBag (v, opt_UF_FunAppDiscount)) (_ILIT(0))
    fun_discount _                     = sizeZero

    ------------
	-- These addSize things have to be here because
	-- I don't want to give them bOMB_OUT_SIZE as an argument

    addSizeN TooBig          _  = TooBig
    addSizeN (SizeIs n xs d) m 	= mkSizeIs bOMB_OUT_SIZE (n +# iUnbox m) xs d
    
    addSize TooBig	      _			= TooBig
    addSize _		      TooBig		= TooBig
    addSize (SizeIs n1 xs d1) (SizeIs n2 ys d2) 
	= mkSizeIs bOMB_OUT_SIZE (n1 +# n2) (xs `unionBags` ys) (d1 +# d2)
\end{code}

Code for manipulating sizes

\begin{code}
data ExprSize = TooBig
	      | SizeIs FastInt		-- Size found
		       (Bag (Id,Int))	-- Arguments cased herein, and discount for each such
		       FastInt		-- Size to subtract if result is scrutinised 
					-- by a case expression

-- subtract the discount before deciding whether to bale out. eg. we
-- want to inline a large constructor application into a selector:
--  	tup = (a_1, ..., a_99)
--  	x = case tup of ...
--
mkSizeIs :: FastInt -> FastInt -> Bag (Id, Int) -> FastInt -> ExprSize
mkSizeIs max n xs d | (n -# d) ># max = TooBig
		    | otherwise	      = SizeIs n xs d
 
maxSize :: ExprSize -> ExprSize -> ExprSize
maxSize TooBig         _ 				  = TooBig
maxSize _              TooBig				  = TooBig
maxSize s1@(SizeIs n1 _ _) s2@(SizeIs n2 _ _) | n1 ># n2  = s1
					      | otherwise = s2

sizeZero, sizeOne :: ExprSize
sizeN :: Int -> ExprSize
conSizeN :: DataCon ->Int -> ExprSize

sizeZero     	= SizeIs (_ILIT(0))  emptyBag (_ILIT(0))
sizeOne      	= SizeIs (_ILIT(1))  emptyBag (_ILIT(0))
sizeN n 	= SizeIs (iUnbox n) emptyBag (_ILIT(0))
conSizeN dc n   
  | isUnboxedTupleCon dc = SizeIs (_ILIT(0)) emptyBag (iUnbox n +# _ILIT(1))
  | otherwise		 = SizeIs (_ILIT(1)) emptyBag (iUnbox n +# _ILIT(1))
	-- Treat constructors as size 1; we are keen to expose them
	-- (and we charge separately for their args).  We can't treat
	-- them as size zero, else we find that (iBox x) has size 1,
	-- which is the same as a lone variable; and hence 'v' will 
	-- always be replaced by (iBox x), where v is bound to iBox x.
	--
	-- However, unboxed tuples count as size zero
	-- I found occasions where we had 
	--	f x y z = case op# x y z of { s -> (# s, () #) }
	-- and f wasn't getting inlined

primOpSize :: PrimOp -> Int -> ExprSize
primOpSize op n_args
 | not (primOpIsDupable op) = sizeN opt_UF_DearOp
 | not (primOpOutOfLine op) = sizeN (2 - n_args)
	-- Be very keen to inline simple primops.
	-- We give a discount of 1 for each arg so that (op# x y z) costs 2.
	-- We can't make it cost 1, else we'll inline let v = (op# x y z) 
	-- at every use of v, which is excessive.
	--
	-- A good example is:
	--	let x = +# p q in C {x}
	-- Even though x get's an occurrence of 'many', its RHS looks cheap,
	-- and there's a good chance it'll get inlined back into C's RHS. Urgh!
 | otherwise	      	    = sizeOne

buildSize :: ExprSize
buildSize = SizeIs (_ILIT(-2)) emptyBag (_ILIT(4))
	-- We really want to inline applications of build
	-- build t (\cn -> e) should cost only the cost of e (because build will be inlined later)
	-- Indeed, we should add a result_discount becuause build is 
	-- very like a constructor.  We don't bother to check that the
	-- build is saturated (it usually is).  The "-2" discounts for the \c n, 
	-- The "4" is rather arbitrary.

augmentSize :: ExprSize
augmentSize = SizeIs (_ILIT(-2)) emptyBag (_ILIT(4))
	-- Ditto (augment t (\cn -> e) ys) should cost only the cost of
	-- e plus ys. The -2 accounts for the \cn 

nukeScrutDiscount :: ExprSize -> ExprSize
nukeScrutDiscount (SizeIs n vs _) = SizeIs n vs (_ILIT(0))
nukeScrutDiscount TooBig          = TooBig

-- When we return a lambda, give a discount if it's used (applied)
lamScrutDiscount :: ExprSize -> ExprSize
lamScrutDiscount (SizeIs n vs _) = case opt_UF_FunAppDiscount of { d -> SizeIs n vs (iUnbox d) }
lamScrutDiscount TooBig          = TooBig
\end{code}


%************************************************************************
%*									*
\subsection[considerUnfolding]{Given all the info, do (not) do the unfolding}
%*									*
%************************************************************************

We have very limited information about an unfolding expression: (1)~so
many type arguments and so many value arguments expected---for our
purposes here, we assume we've got those.  (2)~A ``size'' or ``cost,''
a single integer.  (3)~An ``argument info'' vector.  For this, what we
have at the moment is a Boolean per argument position that says, ``I
will look with great favour on an explicit constructor in this
position.'' (4)~The ``discount'' to subtract if the expression
is being scrutinised. 

Assuming we have enough type- and value arguments (if not, we give up
immediately), then we see if the ``discounted size'' is below some
(semi-arbitrary) threshold.  It works like this: for every argument
position where we're looking for a constructor AND WE HAVE ONE in our
hands, we get a (again, semi-arbitrary) discount [proportion to the
number of constructors in the type being scrutinized].

If we're in the context of a scrutinee ( \tr{(case <expr > of A .. -> ...;.. )})
and the expression in question will evaluate to a constructor, we use
the computed discount size *for the result only* rather than
computing the argument discounts. Since we know the result of
the expression is going to be taken apart, discounting its size
is more accurate (see @sizeExpr@ above for how this discount size
is computed).

We use this one to avoid exporting inlinings that we ``couldn't possibly
use'' on the other side.  Can be overridden w/ flaggery.
Just the same as smallEnoughToInline, except that it has no actual arguments.

\begin{code}
couldBeSmallEnoughToInline :: Int -> CoreExpr -> Bool
couldBeSmallEnoughToInline threshold rhs = case calcUnfoldingGuidance threshold rhs of
                                                UnfoldNever -> False
                                                _           -> True

certainlyWillInline :: Unfolding -> Bool
  -- Sees if the unfolding is pretty certain to inline	
certainlyWillInline (CompulsoryUnfolding {}) = True
certainlyWillInline (InlineRule {})          = True
certainlyWillInline (CoreUnfolding 
    { uf_is_cheap = is_cheap
    , uf_guidance = UnfoldIfGoodArgs {ug_arity = n_vals, ug_size = size}})
  = is_cheap && size - (n_vals +1) <= opt_UF_UseThreshold
certainlyWillInline _
  = False

smallEnoughToInline :: Unfolding -> Bool
smallEnoughToInline (CoreUnfolding {uf_guidance = UnfoldIfGoodArgs {ug_size = size}})
  = size <= opt_UF_UseThreshold
smallEnoughToInline _
  = False
\end{code}

%************************************************************************
%*									*
\subsection{callSiteInline}
%*									*
%************************************************************************

This is the key function.  It decides whether to inline a variable at a call site

callSiteInline is used at call sites, so it is a bit more generous.
It's a very important function that embodies lots of heuristics.
A non-WHNF can be inlined if it doesn't occur inside a lambda,
and occurs exactly once or 
    occurs once in each branch of a case and is small

If the thing is in WHNF, there's no danger of duplicating work, 
so we can inline if it occurs once, or is small

NOTE: we don't want to inline top-level functions that always diverge.
It just makes the code bigger.  Tt turns out that the convenient way to prevent
them inlining is to give them a NOINLINE pragma, which we do in 
StrictAnal.addStrictnessInfoToTopId

\begin{code}
callSiteInline :: DynFlags
	       -> Bool			-- True <=> the Id can be inlined
	       -> Id			-- The Id
	       -> Bool			-- True if there are are no arguments at all (incl type args)
	       -> [Bool]		-- One for each value arg; True if it is interesting
	       -> CallCtxt		-- True <=> continuation is interesting
	       -> Maybe CoreExpr	-- Unfolding, if any


data CallCtxt = BoringCtxt

	      | ArgCtxt Bool	-- We're somewhere in the RHS of function with rules
				--	=> be keener to inline
			Int	-- We *are* the argument of a function with this arg discount
				--	=> be keener to inline
		-- INVARIANT: ArgCtxt False 0 ==> BoringCtxt

	      | ValAppCtxt 	-- We're applied to at least one value arg
				-- This arises when we have ((f x |> co) y)
				-- Then the (f x) has argument 'x' but in a ValAppCtxt

	      | CaseCtxt	-- We're the scrutinee of a case
				-- that decomposes its scrutinee

instance Outputable CallCtxt where
  ppr BoringCtxt    = ptext (sLit "BoringCtxt")
  ppr (ArgCtxt _ _) = ptext (sLit "ArgCtxt")
  ppr CaseCtxt 	    = ptext (sLit "CaseCtxt")
  ppr ValAppCtxt    = ptext (sLit "ValAppCtxt")

callSiteInline dflags active_inline id lone_variable arg_infos cont_info
  = let
	n_val_args  = length arg_infos
    in
    case idUnfolding id of {
	NoUnfolding -> Nothing ;
	OtherCon _  -> Nothing ;

	CompulsoryUnfolding unf_template -> Just unf_template ;
		-- CompulsoryUnfolding => there is no top-level binding
		-- for these things, so we must inline it.
		-- Only a couple of primop-like things have 
		-- compulsory unfoldings (see MkId.lhs).
		-- We don't allow them to be inactive

	InlineRule { uf_tmpl = unf_template, uf_arity = arity, uf_is_top = is_top
		   , uf_is_value = is_value, uf_worker = mb_worker }
	    -> let yes_or_no | not active_inline   = False
			     | n_val_args <  arity = yes_unsat	-- Not enough value args
			     | n_val_args == arity = yes_exact	-- Exactly saturated
			     | otherwise	   = True	-- Over-saturated
	           result | yes_or_no = Just unf_template
	       	 	  | otherwise = Nothing
		   
		   -- See Note [Inlining an InlineRule]
		   is_wrapper = isJust mb_worker 
		   yes_unsat | is_wrapper  = or arg_infos
		   	     | otherwise   = False

		   yes_exact = or arg_infos || interesting_saturated_call
		   interesting_saturated_call 
			= case cont_info of
			    BoringCtxt -> not is_top				-- Note [Nested functions]
			    CaseCtxt   -> not lone_variable || not is_value	-- Note [Lone variables]
			    ArgCtxt {} -> arity > 0 	    			-- Note [Inlining in ArgCtxt]
			    ValAppCtxt -> True					-- Note [Cast then apply]
	       in
	       if dopt Opt_D_dump_inlinings dflags then
		pprTrace ("Considering InlineRule for: " ++ showSDoc (ppr id))
			 (vcat [text "active:" <+> ppr active_inline,
				text "arg infos" <+> ppr arg_infos,
				text "interesting call" <+> ppr interesting_saturated_call,
				text "is value:" <+> ppr is_value,
				text "ANSWER =" <+> if yes_or_no then text "YES" else text "NO"])
			  result
		else result ;

	CoreUnfolding { uf_tmpl = unf_template, uf_is_top = is_top, uf_is_value = is_value,
		        uf_is_cheap = is_cheap, uf_guidance = guidance } ->

    let
	result | yes_or_no = Just unf_template
	       | otherwise = Nothing

 	yes_or_no = active_inline && is_cheap && consider_safe
		-- We consider even the once-in-one-branch
		-- occurrences, because they won't all have been
		-- caught by preInlineUnconditionally.  In particular,
		-- if the occurrence is once inside a lambda, and the
		-- rhs is cheap but not a manifest lambda, then
		-- pre-inline will not have inlined it for fear of
		-- invalidating the occurrence info in the rhs.

	consider_safe
		-- consider_safe decides whether it's a good idea to
		-- inline something, given that there's no
		-- work-duplication issue (the caller checks that).
	  = case guidance of
	      UnfoldNever  -> False
	      UnfoldIfGoodArgs { ug_arity = n_vals_wanted, ug_args = arg_discounts
                               , ug_res = res_discount, ug_size = size }
		  | enough_args && size <= (n_vals_wanted + 1)
			-- Inline unconditionally if there no size increase
			-- Size of call is n_vals_wanted (+1 for the function)
		  -> True

	  	  | otherwise
		  -> some_benefit && small_enough && inline_enough_args

		  where
		    enough_args	= n_val_args >= n_vals_wanted
                    inline_enough_args =
                      not (dopt Opt_InlineIfEnoughArgs dflags) || enough_args


		    some_benefit = or arg_infos || really_interesting_cont
				-- There must be something interesting
				-- about some argument, or the result
				-- context, to make it worth inlining

		    really_interesting_cont 
			| n_val_args <  n_vals_wanted = False	-- Too few args
		    	| n_val_args == n_vals_wanted = interesting_saturated_call
		    	| otherwise		      = True	-- Extra args
		    	-- really_interesting_cont tells if the result of the
		    	-- call is in an interesting context.

		    interesting_saturated_call 
			= case cont_info of
			    BoringCtxt -> not is_top && n_vals_wanted > 0	-- Note [Nested functions] 
			    CaseCtxt   -> not lone_variable || not is_value	-- Note [Lone variables]
			    ArgCtxt {} -> n_vals_wanted > 0 			-- Note [Inlining in ArgCtxt]
			    ValAppCtxt -> True					-- Note [Cast then apply]

		    small_enough = (size - discount) <= opt_UF_UseThreshold
		    discount = computeDiscount n_vals_wanted arg_discounts 
					       res_discount' arg_infos
		    res_discount' = case cont_info of
					BoringCtxt  -> 0
					CaseCtxt    -> res_discount
					_other      -> 4 `min` res_discount
			-- res_discount can be very large when a function returns
			-- construtors; but we only want to invoke that large discount
			-- when there's a case continuation.
			-- Otherwise we, rather arbitrarily, threshold it.  Yuk.
			-- But we want to aovid inlining large functions that return 
			-- constructors into contexts that are simply "interesting"
		
    in    
    if dopt Opt_D_dump_inlinings dflags then
	pprTrace ("Considering inlining: " ++ showSDoc (ppr id))
		 (vcat [text "active:" <+> ppr active_inline,
			text "arg infos" <+> ppr arg_infos,
			text "interesting continuation" <+> ppr cont_info,
			text "is value:" <+> ppr is_value,
			text "is cheap:" <+> ppr is_cheap,
			text "guidance" <+> ppr guidance,
			text "ANSWER =" <+> if yes_or_no then text "YES" else text "NO"])
		  result
    else
    result
    }
\end{code}

Note [Inlining an InlineRule]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
An InlineRules is used for
  (a) pogrammer INLINE pragmas
  (b) inlinings from worker/wrapper

For (a) the RHS may be large, and our contract is that we *only* inline
when the function is applied to all the arguments on the LHS of the
source-code defn.  (The uf_arity in the rule.)

However for worker/wrapper it may be worth inlining even if the 
arity is not satisfied (as we do in the CoreUnfolding case) so we don't
require saturation.


Note [Nested functions]
~~~~~~~~~~~~~~~~~~~~~~~
If a function has a nested defn we also record some-benefit, on the
grounds that we are often able to eliminate the binding, and hence the
allocation, for the function altogether; this is good for join points.
But this only makes sense for *functions*; inlining a constructor
doesn't help allocation unless the result is scrutinised.  UNLESS the
constructor occurs just once, albeit possibly in multiple case
branches.  Then inlining it doesn't increase allocation, but it does
increase the chance that the constructor won't be allocated at all in
the branches that don't use it.

Note [Cast then apply]
~~~~~~~~~~~~~~~~~~~~~~
Consider
   myIndex = __inline_me ( (/\a. <blah>) |> co )
   co :: (forall a. a -> a) ~ (forall a. T a)
     ... /\a.\x. case ((myIndex a) |> sym co) x of { ... } ...

We need to inline myIndex to unravel this; but the actual call (myIndex a) has
no value arguments.  The ValAppCtxt gives it enough incentive to inline.

Note [Inlining in ArgCtxt]
~~~~~~~~~~~~~~~~~~~~~~~~~~
The condition (n_vals_wanted > 0) here is very important, because otherwise
we end up inlining top-level stuff into useless places; eg
   x = I# 3#
   f = \y.  g x
This can make a very big difference: it adds 16% to nofib 'integer' allocs,
and 20% to 'power'.

At one stage I replaced this condition by 'True' (leading to the above 
slow-down).  The motivation was test eyeball/inline1.hs; but that seems
to work ok now.

Note [Lone variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The "lone-variable" case is important.  I spent ages messing about
with unsatisfactory varaints, but this is nice.  The idea is that if a
variable appears all alone
	as an arg of lazy fn, or rhs	Stop
	as scrutinee of a case		Select
	as arg of a strict fn		ArgOf
AND
	it is bound to a value
then we should not inline it (unless there is some other reason,
e.g. is is the sole occurrence).  That is what is happening at 
the use of 'lone_variable' in 'interesting_saturated_call'.

Why?  At least in the case-scrutinee situation, turning
	let x = (a,b) in case x of y -> ...
into
	let x = (a,b) in case (a,b) of y -> ...
and thence to 
	let x = (a,b) in let y = (a,b) in ...
is bad if the binding for x will remain.

Another example: I discovered that strings
were getting inlined straight back into applications of 'error'
because the latter is strict.
	s = "foo"
	f = \x -> ...(error s)...

Fundamentally such contexts should not encourage inlining because the
context can ``see'' the unfolding of the variable (e.g. case or a
RULE) so there's no gain.  If the thing is bound to a value.

However, watch out:

 * Consider this:
	foo = _inline_ (\n. [n])
	bar = _inline_ (foo 20)
	baz = \n. case bar of { (m:_) -> m + n }
   Here we really want to inline 'bar' so that we can inline 'foo'
   and the whole thing unravels as it should obviously do.  This is 
   important: in the NDP project, 'bar' generates a closure data
   structure rather than a list. 

 * Even a type application or coercion isn't a lone variable.
   Consider
	case $fMonadST @ RealWorld of { :DMonad a b c -> c }
   We had better inline that sucker!  The case won't see through it.

   For now, I'm treating treating a variable applied to types 
   in a *lazy* context "lone". The motivating example was
	f = /\a. \x. BIG
	g = /\a. \y.  h (f a)
   There's no advantage in inlining f here, and perhaps
   a significant disadvantage.  Hence some_val_args in the Stop case

\begin{code}
computeDiscount :: Int -> [Int] -> Int -> [Bool] -> Int
computeDiscount n_vals_wanted arg_discounts result_discount arg_infos
 	-- We multiple the raw discounts (args_discount and result_discount)
	-- ty opt_UnfoldingKeenessFactor because the former have to do with
	--  *size* whereas the discounts imply that there's some extra 
	--  *efficiency* to be gained (e.g. beta reductions, case reductions) 
	-- by inlining.

	-- we also discount 1 for each argument passed, because these will
	-- reduce with the lambdas in the function (we count 1 for a lambda
 	-- in size_up).
  = 1 +			-- Discount of 1 because the result replaces the call
			-- so we count 1 for the function itself
    length (take n_vals_wanted arg_infos) +
			-- Discount of 1 for each arg supplied, because the 
			-- result replaces the call
    round (opt_UF_KeenessFactor * 
	   fromIntegral (arg_discount + result_discount))
  where
    arg_discount = sum (zipWith mk_arg_discount arg_discounts arg_infos)

    mk_arg_discount discount is_evald | is_evald  = discount
				      | otherwise = 0
\end{code}

%************************************************************************
%*									*
	The Very Simple Optimiser
%*									*
%************************************************************************


\begin{code}
simpleOptExpr :: CoreExpr -> CoreExpr
-- Return an occur-analysed and slightly optimised expression
-- The optimisation is very straightforward: just
-- inline non-recursive bindings that are used only once, 
-- or wheere the RHS is trivial

simpleOptExpr expr
  = go emptySubst (occurAnalyseExpr expr)
  where
    go subst (Var v)          = lookupIdSubst subst v
    go subst (App e1 e2)      = App (go subst e1) (go subst e2)
    go subst (Type ty)        = Type (substTy subst ty)
    go _     (Lit lit)        = Lit lit
    go subst (Note note e)    = Note note (go subst e)
    go subst (Cast e co)      = Cast (go subst e) (substTy subst co)
    go subst (Let bind body)  = go_bind subst bind body
    go subst (Lam bndr body)  = Lam bndr' (go subst' body)
		              where
			        (subst', bndr') = substBndr subst bndr

    go subst (Case e b ty as) = Case (go subst e) b' 
				     (substTy subst ty)
				     (map (go_alt subst') as)
			      where
			  	 (subst', b') = substBndr subst b


    ----------------------
    go_alt subst (con, bndrs, rhs) = (con, bndrs', go subst' rhs)
				 where
				   (subst', bndrs') = substBndrs subst bndrs

    ----------------------
    go_bind subst (Rec prs) body = Let (Rec (bndrs' `zip` rhss'))
				       (go subst' body)
			    where
			      (bndrs, rhss)    = unzip prs
			      (subst', bndrs') = substRecBndrs subst bndrs
			      rhss'	       = map (go subst') rhss

    go_bind subst (NonRec b r) body = go_nonrec subst b (go subst r) body

    ----------------------
    go_nonrec subst b (Type ty') body
      | isTyVar b = go (extendTvSubst subst b ty') body
	-- let a::* = TYPE ty in <body>
    go_nonrec subst b r' body
      | isId b	-- let x = e in <body>
      , exprIsTrivial r' || safe_to_inline (idOccInfo b)
      = go (extendIdSubst subst b r') body
    go_nonrec subst b r' body
      = Let (NonRec b' r') (go subst' body)
      where
	(subst', b') = substBndr subst b

    ----------------------
	-- Unconditionally safe to inline
    safe_to_inline :: OccInfo -> Bool
    safe_to_inline IAmDead                  = True
    safe_to_inline (OneOcc in_lam one_br _) = not in_lam && one_br
    safe_to_inline (IAmALoopBreaker {})     = False
    safe_to_inline NoOccInfo                = False
\end{code}