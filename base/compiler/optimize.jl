# This file is a part of Julia. License is MIT: https://julialang.org/license

#####################
# OptimizationState #
#####################

mutable struct OptimizationState
    linfo::MethodInstance
    result_vargs::Vector{Any}
    backedges::Vector{Any}
    src::CodeInfo
    mod::Module
    nargs::Int
    next_label::Int # index of the current highest label for this function
    min_valid::UInt
    max_valid::UInt
    params::Params
    function OptimizationState(frame::InferenceState)
        s_edges = frame.stmt_edges[1]
        if s_edges === ()
            s_edges = []
            frame.stmt_edges[1] = s_edges
        end
        src = frame.src
        next_label = max(label_counter(src.code), length(src.code)) + 10
        return new(frame.linfo, frame.result.vargs,
                   s_edges::Vector{Any},
                   src, frame.mod, frame.nargs,
                   next_label, frame.min_valid, frame.max_valid,
                   frame.params)
    end
    function OptimizationState(linfo::MethodInstance, src::CodeInfo,
                               params::Params)
        # prepare src for running optimization passes
        # if it isn't already
        nssavalues = src.ssavaluetypes
        if nssavalues isa Int
            src.ssavaluetypes = Any[ Any for i = 1:nssavalues ]
        end
        if src.slottypes === nothing
            nslots = length(src.slotnames)
            src.slottypes = Any[ Any for i = 1:nslots ]
        end
        s_edges = []
        # cache some useful state computations
        toplevel = !isa(linfo.def, Method)
        if !toplevel
            meth = linfo.def
            inmodule = meth.module
            nargs = meth.nargs
        else
            inmodule = linfo.def::Module
            nargs = 0
        end
        next_label = max(label_counter(src.code), length(src.code)) + 10
        result_vargs = Any[] # if you want something more accurate, set it yourself :P
        return new(linfo, result_vargs,
                   s_edges::Vector{Any},
                   src, inmodule, nargs,
                   next_label,
                   min_world(linfo), max_world(linfo),
                   params)
    end
end

function OptimizationState(linfo::MethodInstance, params::Params)
    src = retrieve_code_info(linfo)
    src === nothing && return nothing
    return OptimizationState(linfo, src, params)
end

include("compiler/ssair/driver.jl")

_topmod(sv::OptimizationState) = _topmod(sv.mod)

function update_valid_age!(min_valid::UInt, max_valid::UInt, sv::OptimizationState)
    sv.min_valid = max(sv.min_valid, min_valid)
    sv.max_valid = min(sv.max_valid, max_valid)
    @assert(!isa(sv.linfo.def, Method) ||
            (sv.min_valid == typemax(UInt) && sv.max_valid == typemin(UInt)) ||
            sv.min_valid <= sv.params.world <= sv.max_valid,
            "invalid age range update")
    nothing
end

update_valid_age!(li::MethodInstance, sv::OptimizationState) = update_valid_age!(min_world(li), max_world(li), sv)

function add_backedge!(li::MethodInstance, caller::OptimizationState)
    isa(caller.linfo.def, Method) || return # don't add backedges to toplevel exprs
    push!(caller.backedges, li)
    update_valid_age!(li, caller)
    nothing
end

###########
# structs #
###########

struct InvokeData
    mt::Core.MethodTable
    entry::Core.TypeMapEntry
    types0
    fexpr
    texpr
end

#############
# constants #
#############

# The slot has uses that are not statically dominated by any assignment
# This is implied by `SLOT_USEDUNDEF`.
# If this is not set, all the uses are (statically) dominated by the defs.
# In particular, if a slot has `AssignedOnce && !StaticUndef`, it is an SSA.
const SLOT_STATICUNDEF  = 1

const SLOT_ASSIGNEDONCE = 16 # slot is assigned to only once

const SLOT_USEDUNDEF    = 32 # slot has uses that might raise UndefVarError

# const SLOT_CALLED      = 64

const IR_FLAG_INBOUNDS = 0x01


# known affect-free calls (also effect-free)
const _PURE_BUILTINS = Any[tuple, svec, fieldtype, apply_type, ===, isa, typeof, UnionAll, nfields]

# known effect-free calls (might not be affect-free)
const _PURE_BUILTINS_VOLATILE = Any[getfield, arrayref, isdefined, Core.sizeof]

const TOP_TUPLE = GlobalRef(Core, :tuple)

#########
# logic #
#########

function isinlineable(m::Method, src::CodeInfo, mod::Module, params::Params, bonus::Int=0)
    # compute the cost (size) of inlining this code
    inlineable = false
    cost_threshold = params.inline_cost_threshold
    if m.module === _topmod(m.module)
        # a few functions get special treatment
        name = m.name
        sig = m.sig
        if ((name === :+ || name === :* || name === :min || name === :max) &&
            isa(sig,DataType) &&
            sig == Tuple{sig.parameters[1],Any,Any,Any,Vararg{Any}})
            inlineable = true
        elseif (name === :iterate || name === :unsafe_convert ||
                name === :cconvert)
            cost_threshold *= 4
        end
    end
    if !inlineable
        inlineable = inline_worthy(src.code, src, mod, params, cost_threshold + bonus)
    end
    return inlineable
end

# converge the optimization work
function optimize(me::InferenceState)
    # annotate fulltree with type information
    type_annotate!(me)

    # run optimization passes on fulltree
    force_noinline = true
    def = me.linfo.def
    if me.limited && me.cached && me.parent !== nothing
        # a top parent will be cached still, but not this intermediate work
        me.cached = false
        me.linfo.inInference = false
    elseif me.optimize
        opt = OptimizationState(me)
        reindex_labels!(opt)
        nargs = Int(opt.nargs) - 1
        if def isa Method
            topline = LineInfoNode(opt.mod, def.name, def.file, Int(def.line), 0)
        else
            topline = LineInfoNode(opt.mod, NullLineInfo.method, NullLineInfo.file, 0, 0)
        end
        linetable = [topline]
        @timeit "optimizer" ir = run_passes(opt.src, nargs, linetable, opt)
        force_noinline = any(x->isexpr(x, :meta) && x.args[1] == :noinline, ir.meta)
        replace_code_newstyle!(opt.src, ir, nargs, linetable)
        me.min_valid = opt.min_valid
        me.max_valid = opt.max_valid
    end

    # convert all type information into the form consumed by the code-generator
    widen_all_consts!(me.src)

    # compute inlining and other related properties
    me.const_ret = (isa(me.bestguess, Const) || isconstType(me.bestguess))
    if me.const_ret
        proven_pure = false
        # must be proven pure to use const_api; otherwise we might skip throwing errors
        # (issue #20704)
        # TODO: Improve this analysis; if a function is marked @pure we should really
        # only care about certain errors (e.g. method errors and type errors).
        if length(me.src.code) < 10
            proven_pure = true
            for stmt in me.src.code
                if !statement_effect_free(stmt, me.src, me.mod)
                    proven_pure = false
                    break
                end
            end
            if proven_pure
                for fl in me.src.slotflags
                    if (fl & SLOT_USEDUNDEF) != 0
                        proven_pure = false
                        break
                    end
                end
            end
        end
        if proven_pure
            me.src.pure = true
        end

        if proven_pure && !coverage_enabled()
            # use constant calling convention
            # Do not emit `jl_fptr_const_return` if coverage is enabled
            # so that we don't need to add coverage support
            # to the `jl_call_method_internal` fast path
            # Still set pure flag to make sure `inference` tests pass
            # and to possibly enable more optimization in the future
            if !(isa(me.bestguess, Const) && !is_inlineable_constant(me.bestguess.val))
                me.const_api = true
            end
            force_noinline || (me.src.inlineable = true)
        end
    end

    # determine and cache inlineability
    if !force_noinline
        # don't keep ASTs for functions specialized on a Union argument
        # TODO: this helps avoid a type-system bug mis-computing sparams during intersection
        sig = unwrap_unionall(me.linfo.specTypes)
        if isa(sig, DataType) && sig.name === Tuple.name
            for P in sig.parameters
                P = unwrap_unionall(P)
                if isa(P, Union)
                    force_noinline = true
                    break
                end
            end
        else
            force_noinline = true
        end
    end
    if force_noinline
        me.src.inlineable = false
    elseif !me.src.inlineable && isa(def, Method)
        bonus = 0
        if me.bestguess ⊑ Tuple && !isbitstype(widenconst(me.bestguess))
            bonus = me.params.inline_tupleret_bonus
        end
        me.src.inlineable = isinlineable(def, me.src, me.mod, me.params, bonus)
    end
    me.src.inferred = true
    if me.optimize && !(me.limited && me.parent !== nothing)
        validate_code_in_debug_mode(me.linfo, me.src, "optimized")
    end
    nothing
end

# inference completed on `me`
# update the MethodInstance and notify the edges
function finish(me::InferenceState)
    if me.cached
        toplevel = !isa(me.linfo.def, Method)
        if !toplevel
            min_valid = me.min_valid
            max_valid = me.max_valid
        else
            min_valid = UInt(0)
            max_valid = UInt(0)
        end

        # check if the existing me.linfo metadata is also sufficient to describe the current inference result
        # to decide if it is worth caching it again (which would also clear any generated code)
        already_inferred = !me.linfo.inInference
        if isdefined(me.linfo, :inferred)
            inf = me.linfo.inferred
            if !isa(inf, CodeInfo) || (inf::CodeInfo).inferred
                if min_world(me.linfo) == min_valid && max_world(me.linfo) == max_valid
                    already_inferred = true
                end
            end
        end

        # don't store inferred code if we've decided to interpret this function
        if !already_inferred && invoke_api(me.linfo) != 4
            const_flags = (me.const_ret) << 1 | me.const_api
            if me.const_ret
                if isa(me.bestguess, Const)
                    inferred_const = (me.bestguess::Const).val
                else
                    @assert isconstType(me.bestguess)
                    inferred_const = me.bestguess.parameters[1]
                end
            else
                inferred_const = nothing
            end
            if me.const_api
                # use constant calling convention
                inferred_result = nothing
            else
                inferred_result = me.src
            end

            if !toplevel
                if !me.const_api
                    def = me.linfo.def::Method
                    keeptree = me.optimize &&
                        (me.src.inlineable ||
                         ccall(:jl_isa_compileable_sig, Int32, (Any, Any), me.linfo.specTypes, def) != 0)
                    if keeptree
                        # compress code for non-toplevel thunks
                        inferred_result = ccall(:jl_compress_ast, Any, (Any, Any), def, inferred_result)
                    else
                        inferred_result = nothing
                    end
                end
            end
            cache = ccall(:jl_set_method_inferred, Ref{MethodInstance}, (Any, Any, Any, Any, Int32, UInt, UInt),
                me.linfo, widenconst(me.bestguess), inferred_const, inferred_result,
                const_flags, min_valid, max_valid)
            if cache !== me.linfo
                me.linfo.inInference = false
                me.linfo = cache
                me.result.linfo = cache
            end
        end
        me.linfo.inInference = false
    end

    # finish updating the result struct
    if me.src.inlineable
        me.result.src = me.src # stash a copy of the code (for inlining)
    end
    me.result.result = me.bestguess # record type, and that wip is done and me.linfo can be used as a backedge

    # update all of the callers with real backedges by traversing the temporary list of backedges
    for (i, _) in me.backedges
        add_backedge!(me.linfo, i)
    end

    # finalize and record the linfo result
    me.inferred = true
    nothing
end

function maybe_widen_conditional(vt)
    if isa(vt, Conditional)
        if vt.vtype === Bottom
            vt = Const(false)
        elseif vt.elsetype === Bottom
            vt = Const(true)
        end
    end
    vt
end

function annotate_slot_load!(e::Expr, vtypes::VarTable, sv::InferenceState, undefs::Array{Bool,1})
    head = e.head
    i0 = 1
    e.typ = maybe_widen_conditional(e.typ)
    if is_meta_expr_head(head) || head === :const
        return
    end
    if head === :(=) || head === :method
        i0 = 2
    end
    for i = i0:length(e.args)
        subex = e.args[i]
        if isa(subex, Expr)
            annotate_slot_load!(subex, vtypes, sv, undefs)
        elseif isa(subex, Slot)
            id = slot_id(subex)
            s = vtypes[id]
            vt = maybe_widen_conditional(s.typ)
            if s.undef
                # find used-undef variables
                undefs[id] = true
            end
            #  add type annotations where needed
            if !(sv.src.slottypes[id] ⊑ vt)
                e.args[i] = TypedSlot(id, vt)
            end
        end
    end
end

function record_slot_assign!(sv::InferenceState)
    # look at all assignments to slots
    # and union the set of types stored there
    # to compute a lower bound on the storage required
    states = sv.stmt_types
    body = sv.src.code::Vector{Any}
    slottypes = sv.src.slottypes::Vector{Any}
    for i = 1:length(body)
        expr = body[i]
        st_i = states[i]
        # find all reachable assignments to locals
        if isa(st_i, VarTable) && isa(expr, Expr) && expr.head === :(=)
            lhs = expr.args[1]
            rhs = expr.args[2]
            if isa(lhs, Slot)
                id = slot_id(lhs)
                if isa(rhs, Slot)
                    # exprtype isn't yet computed for slots
                    vt = st_i[slot_id(rhs)].typ
                else
                    vt = exprtype(rhs, sv.src, sv.mod)
                end
                vt = widenconst(vt)
                if vt !== Bottom
                    otherTy = slottypes[id]
                    if otherTy === Bottom
                        slottypes[id] = vt
                    elseif otherTy === Any
                        slottypes[id] = Any
                    else
                        slottypes[id] = tmerge(otherTy, vt)
                    end
                end
            end
        end
    end
end

# annotate types of all symbols in AST
function type_annotate!(sv::InferenceState)
    # remove all unused ssa values
    gt = sv.src.ssavaluetypes
    for j = 1:length(gt)
        if gt[j] === NOT_FOUND
            gt[j] = Union{}
        end
    end

    # compute the required type for each slot
    # to hold all of the items assigned into it
    record_slot_assign!(sv)

    # annotate variables load types
    # remove dead code
    # and compute which variables may be used undef
    src = sv.src
    states = sv.stmt_types
    nargs = sv.nargs
    nslots = length(states[1])
    undefs = fill(false, nslots)
    body = src.code::Array{Any,1}
    nexpr = length(body)
    push!(body, LabelNode(nexpr + 1)) # add a terminal label for tracking phi
    i = 1
    while i <= nexpr
        st_i = states[i]
        expr = body[i]
        if isa(st_i, VarTable)
            # st_i === ()  =>  unreached statement  (see issue #7836)
            if isa(expr, Expr)
                annotate_slot_load!(expr, st_i, sv, undefs)
            elseif isa(expr, Slot)
                id = slot_id(expr)
                if st_i[id].undef
                    # find used-undef variables in statement position
                    undefs[id] = true
                end
            end
        elseif sv.optimize
            if ((isa(expr, Expr) && is_meta_expr(expr)) ||
                 isa(expr, LineNumberNode))
                # keep any lexically scoped expressions
                i += 1
                continue
            end
            # This can create `Expr(:gotoifnot)` with dangling label, which we
            # will clean up by replacing them with the conditions later.
            deleteat!(body, i)
            deleteat!(states, i)
            nexpr -= 1
            continue
        end
        i += 1
    end

    # finish marking used-undef variables
    for j = 1:nslots
        if undefs[j]
            src.slotflags[j] |= SLOT_USEDUNDEF | SLOT_STATICUNDEF
        end
    end

    # The dead code elimination can delete the target of a reachable node. This
    # must mean that the target is unreachable. Later optimization passes will
    # assume that all branches lead to labels that exist, so we must replace
    # the node with the branch condition (which may have side effects).
    labelmap = get_label_map(body)
    for i in 1:length(body)
        expr = body[i]
        if isa(expr, Expr) && expr.head === :gotoifnot
            labelnum = labelmap[expr.args[2]::Int]
            if labelnum === 0
                body[i] = expr.args[1]
            end
        end
    end
    nothing
end

# widen all Const elements in type annotations
function _widen_all_consts!(e::Expr, untypedload::Vector{Bool}, slottypes::Vector{Any})
    e.typ = widenconst(e.typ)
    for i = 1:length(e.args)
        x = e.args[i]
        if isa(x, Expr)
            _widen_all_consts!(x, untypedload, slottypes)
        elseif isa(x, TypedSlot)
            vt = widenconst(x.typ)
            if !(vt === x.typ)
                if slottypes[x.id] ⊑ vt
                    x = SlotNumber(x.id)
                    untypedload[x.id] = true
                else
                    x = TypedSlot(x.id, vt)
                end
                e.args[i] = x
            end
        elseif isa(x, PiNode)
            e.args[i] = PiNode(x.val, widenconst(x.typ))
        elseif isa(x, SlotNumber) && (i != 1 || e.head !== :(=))
            untypedload[x.id] = true
        end
    end
    nothing
end

function widen_all_consts!(src::CodeInfo)
    for i = 1:length(src.ssavaluetypes)
        src.ssavaluetypes[i] = widenconst(src.ssavaluetypes[i])
    end
    for i = 1:length(src.slottypes)
        src.slottypes[i] = widenconst(src.slottypes[i])
    end

    nslots = length(src.slottypes)
    untypedload = fill(false, nslots)
    e = Expr(:body)
    e.args = src.code
    _widen_all_consts!(e, untypedload, src.slottypes)
    for i = 1:nslots
        src.slottypes[i] = widen_slot_type(src.slottypes[i], untypedload[i])
    end
    return src
end

# widen all slots to their optimal storage layout
# we also need to preserve the type for any untyped load of a DataType
# since codegen optimizations of functions like `is` will depend on knowing it
function widen_slot_type(@nospecialize(ty), untypedload::Bool)
    if isa(ty, DataType)
        if untypedload || isbitstype(ty) || isdefined(ty, :instance)
            return ty
        end
    elseif isa(ty, Union)
        ty_a = widen_slot_type(ty.a, false)
        ty_b = widen_slot_type(ty.b, false)
        if ty_a !== Any || ty_b !== Any
            # TODO: better optimized codegen for unions?
            return ty
        end
    elseif isa(ty, UnionAll)
        if untypedload
            return ty
        end
    end
    return Any
end

# replace slots 1:na with argexprs, static params with spvals, and increment
# other slots by offset.
function substitute!(
        @nospecialize(e), na::Int, argexprs::Vector{Any},
        @nospecialize(spsig), spvals::Vector{Any},
        offset::Int, boundscheck::Symbol)
    if isa(e, Slot)
        id = slot_id(e)
        if 1 <= id <= na
            ae = argexprs[id]
            if isa(e, TypedSlot) && isa(ae, Slot)
                return TypedSlot(ae.id, e.typ)
            end
            return ae
        end
        if isa(e, SlotNumber)
            return SlotNumber(id + offset)
        else
            return TypedSlot(id + offset, e.typ)
        end
    end
    if isa(e, NewvarNode)
        return NewvarNode(substitute!(e.slot, na, argexprs, spsig, spvals, offset, boundscheck))
    end
    if isa(e, PhiNode)
        values = Vector{Any}(undef, length(e.values))
        for i = 1:length(values)
            isassigned(e.values, i) || continue
            values[i] = substitute!(e.values[i], na, argexprs, spsig,
                spvals, offset, boundscheck)
        end
        return PhiNode(e.edges, values)
    end
    if isa(e, PiNode)
        return PiNode(substitute!(e.val, na, argexprs, spsig, spvals, offset, boundscheck), e.typ)
    end
    if isa(e, Expr)
        e = e::Expr
        head = e.head
        if head === :static_parameter
            return quoted(spvals[e.args[1]])
        elseif head === :cfunction
            @assert !isa(spsig, UnionAll) || !isempty(spvals)
            if !(e.args[2] isa QuoteNode) # very common no-op
                e.args[2] = substitute!(e.args[2], na, argexprs, spsig, spvals, offset, boundscheck)
            end
            e.args[3] = ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), e.args[3], spsig, spvals)
            e.args[4] = svec(Any[
                ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), argt, spsig, spvals)
                for argt
                in e.args[4] ]...)
        elseif head === :foreigncall
            @assert !isa(spsig, UnionAll) || !isempty(spvals)
            for i = 1:length(e.args)
                if i == 2
                    e.args[2] = ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), e.args[2], spsig, spvals)
                elseif i == 3
                    e.args[3] = svec(Any[
                        ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), argt, spsig, spvals)
                        for argt
                        in e.args[3] ]...)
                elseif i == 4
                    @assert isa((e.args[4]::QuoteNode).value, Symbol)
                elseif i == 5
                    @assert isa(e.args[5], Int)
                else
                    e.args[i] = substitute!(e.args[i], na, argexprs, spsig, spvals, offset, boundscheck)
                end
            end
        elseif head === :boundscheck
            if boundscheck === :propagate
                return e
            elseif boundscheck === :off
                return false
            else
                return true
            end
        elseif !is_meta_expr_head(head)
            for i = 1:length(e.args)
                e.args[i] = substitute!(e.args[i], na, argexprs, spsig, spvals, offset, boundscheck)
            end
        end
    end
    return e
end

# whether `f` is pure for inference
function is_pure_intrinsic_infer(f::IntrinsicFunction)
    return !(f === Intrinsics.pointerref || # this one is volatile
             f === Intrinsics.pointerset || # this one is never effect-free
             f === Intrinsics.llvmcall ||   # this one is never effect-free
             f === Intrinsics.arraylen ||   # this one is volatile
             f === Intrinsics.sqrt_llvm ||  # this one may differ at runtime (by a few ulps)
             f === Intrinsics.cglobal)  # cglobal lookup answer changes at runtime
end

# whether `f` is pure for optimizations
function is_pure_intrinsic_optim(f::IntrinsicFunction)
    return !(f === Intrinsics.pointerref || # this one is volatile
             f === Intrinsics.pointerset || # this one is never effect-free
             f === Intrinsics.llvmcall ||   # this one is never effect-free
             f === Intrinsics.arraylen ||   # this one is volatile
             f === Intrinsics.checked_sdiv_int ||  # these may throw errors
             f === Intrinsics.checked_udiv_int ||
             f === Intrinsics.checked_srem_int ||
             f === Intrinsics.checked_urem_int ||
             f === Intrinsics.cglobal)  # cglobal throws an error for symbol-not-found
end

function is_pure_builtin(@nospecialize(f))
    if isa(f, IntrinsicFunction)
        return is_pure_intrinsic_optim(f)
    elseif isa(f, Builtin)
        return (contains_is(_PURE_BUILTINS, f) ||
                contains_is(_PURE_BUILTINS_VOLATILE, f))
    else
        return f === return_type
    end
end

function statement_effect_free(@nospecialize(e), src, mod::Module)
    if isa(e, Expr)
        if e.head === :(=)
            return !isa(e.args[1], GlobalRef) && effect_free(e.args[2], src, mod, false)
        elseif e.head === :gotoifnot
            return effect_free(e.args[1], src, mod, false)
        end
    elseif isa(e, LabelNode) || isa(e, GotoNode)
        return true
    end
    return effect_free(e, src, mod, false)
end

# detect some important side-effect-free calls (allow_volatile=true)
# and some affect-free calls (allow_volatile=false) -- affect_free means the call
# cannot be affected by previous calls, except assignment nodes
function effect_free(@nospecialize(e), src, mod::Module, allow_volatile::Bool)
    if isa(e, GlobalRef)
        return (isdefined(e.mod, e.name) && (allow_volatile || isconst(e.mod, e.name)))
    elseif isa(e, Symbol)
        return allow_volatile
    elseif isa(e, Slot)
        return src.slotflags[slot_id(e)] & SLOT_USEDUNDEF == 0
    elseif isa(e, Expr)
        e = e::Expr
        head = e.head
        if is_meta_expr_head(head)
            return true
        end
        if head === :static_parameter
            # if we aren't certain enough about the type, it might be an UndefVarError at runtime
            return isa(e.typ, Const) || issingletontype(widenconst(e.typ))
        end
        if e.typ === Bottom
            return false
        end
        ea = e.args
        if head === :call
            if is_known_call_p(e, is_pure_builtin, src, mod)
                if !allow_volatile
                    if is_known_call(e, arrayref, src, mod) || is_known_call(e, arraylen, src, mod)
                        return false
                    elseif is_known_call(e, getfield, src, mod)
                        nargs = length(ea)
                        (3 <= nargs <= 4) || return false
                        et = exprtype(e, src, mod)
                        # TODO: check ninitialized
                        if !isa(et, Const) && !isconstType(et)
                            # first argument must be immutable to ensure e is affect_free
                            a = ea[2]
                            typ = unwrap_unionall(widenconst(exprtype(a, src, mod)))
                            if isType(typ)
                                # all fields of subtypes of Type are effect-free
                                # (including the non-inferrable uid field)
                            elseif !isa(typ, DataType) || typ.abstract || (typ.mutable && length(typ.types) > 0)
                                return false
                            end
                        end
                    end
                end
                # fall-through
            elseif is_known_call(e, _apply, src, mod) && length(ea) > 1
                ft = exprtype(ea[2], src, mod)
                if !isa(ft, Const) || (!contains_is(_PURE_BUILTINS, ft.val) &&
                                       ft.val !== Core.sizeof)
                    return false
                end
                # fall-through
            else
                return false
            end
        elseif head === :new
            a = ea[1]
            typ = exprtype(a, src, mod)
            # `Expr(:new)` of unknown type could raise arbitrary TypeError.
            typ, isexact = instanceof_tfunc(typ)
            isexact || return false
            isconcretedispatch(typ) || return false
            typ = typ::DataType
            if !allow_volatile && typ.mutable
                return false
            end
            fieldcount(typ) >= length(ea) - 1 || return false
            for fld_idx in 1:(length(ea) - 1)
                eT = exprtype(ea[fld_idx + 1], src, mod)
                fT = fieldtype(typ, fld_idx)
                eT ⊑ fT || return false
            end
            # fall-through
        elseif head === :return
            # fall-through
        elseif head === :isdefined
            return allow_volatile
        elseif head === :the_exception
            return allow_volatile
        elseif head === :copyast
            return true
        else
            return false
        end
        for a in ea
            if !effect_free(a, src, mod, allow_volatile)
                return false
            end
        end
    elseif isa(e, LabelNode) || isa(e, GotoNode)
        return false
    end
    return true
end

function countunionsplit(atypes)
    nu = 1
    for ti in atypes
        if isa(ti, Union)
            nu *= unionlen(ti::Union)
        end
    end
    return nu
end

## Computing the cost of a function body

# saturating sum (inputs are nonnegative), prevents overflow with typemax(Int) below
plus_saturate(x, y) = max(x, y, x+y)

# known return type
isknowntype(@nospecialize T) = (T == Union{}) || isconcretetype(T)

function statement_cost(ex::Expr, line::Int, src::CodeInfo, mod::Module, params::Params)
    head = ex.head
    if is_meta_expr(ex) || head == :copyast # not sure if copyast is right
        return 0
    end
    argcost = 0
    for a in ex.args
        if a isa Expr
            argcost = plus_saturate(argcost, statement_cost(a, line, src, mod, params))
        end
    end
    if head == :return || head == :(=)
        return argcost
    end
    if head == :call
        extyp = exprtype(ex.args[1], src, mod)
        if isa(extyp, Type)
            return argcost
        end
        if isa(extyp, Const)
            f = (extyp::Const).val
            if isa(f, IntrinsicFunction)
                iidx = Int(reinterpret(Int32, f::IntrinsicFunction)) + 1
                if !isassigned(T_IFUNC_COST, iidx)
                    # unknown/unhandled intrinsic
                    return plus_saturate(argcost, params.inline_nonleaf_penalty)
                end
                return plus_saturate(argcost, T_IFUNC_COST[iidx])
            end
            if isa(f, Builtin)
                # The efficiency of operations like a[i] and s.b
                # depend strongly on whether the result can be
                # inferred, so check ex.typ
                if f == Main.Core.getfield || f == Main.Core.tuple
                    # we might like to penalize non-inferrability, but
                    # tuple iteration/destructuring makes that
                    # impossible
                    # return plus_saturate(argcost, isknowntype(ex.typ) ? 1 : params.inline_nonleaf_penalty)
                    return argcost
                elseif f == Main.Core.arrayref
                    return plus_saturate(argcost, isknowntype(ex.typ) ? 4 : params.inline_nonleaf_penalty)
                end
                fidx = findfirst(x->x===f, T_FFUNC_KEY)
                if fidx === nothing
                    # unknown/unhandled builtin or anonymous function
                    # Use the generic cost of a direct function call
                    return plus_saturate(argcost, 20)
                end
                return plus_saturate(argcost, T_FFUNC_COST[fidx])
            end
        end
        return plus_saturate(argcost, params.inline_nonleaf_penalty)
    elseif head == :foreigncall || head == :invoke
        # Calls whose "return type" is Union{} do not actually return:
        # they are errors. Since these are not part of the typical
        # run-time of the function, we omit them from
        # consideration. This way, non-inlined error branches do not
        # prevent inlining.
        return ex.typ == Union{} ? 0 : plus_saturate(20, argcost)
    elseif head == :llvmcall
        return plus_saturate(10, argcost) # a wild guess at typical cost
    elseif head == :enter
        # try/catch is a couple function calls,
        # but don't inline functions with try/catch
        # since these aren't usually performance-sensitive functions,
        # and llvm is more likely to miscompile them when these functions get large
        return typemax(Int)
    elseif head == :gotoifnot
        target = ex.args[2]::Int
        # loops are generally always expensive
        # but assume that forward jumps are already counted for from
        # summing the cost of the not-taken branch
        return target < line ? plus_saturate(40, argcost) : argcost
    end
    return argcost
end

function inline_worthy(body::Array{Any,1}, src::CodeInfo, mod::Module,
                       params::Params,
                       cost_threshold::Integer=params.inline_cost_threshold)
    bodycost = 0
    for line = 1:length(body)
        stmt = body[line]
        if stmt isa Expr
            thiscost = statement_cost(stmt, line, src, mod, params)::Int
        elseif stmt isa GotoNode
            # loops are generally always expensive
            # but assume that forward jumps are already counted for from
            # summing the cost of the not-taken branch
            thiscost = stmt.label < line ? 40 : 0
        else
            continue
        end
        bodycost = plus_saturate(bodycost, thiscost)
        bodycost == typemax(Int) && return false
    end
    return bodycost <= cost_threshold
end

function inline_worthy(body::Expr, src::CodeInfo, mod::Module, params::Params,
                       cost_threshold::Integer=params.inline_cost_threshold)
    bodycost = statement_cost(body, typemax(Int), src, mod, params)
    return bodycost <= cost_threshold
end

function inline_worthy(@nospecialize(body), src::CodeInfo, mod::Module, params::Params,
                       cost_threshold::Integer=params.inline_cost_threshold)
    newbody = exprtype(body, src, mod)
    !isa(newbody, Expr) && return true
    return inline_worthy(newbody, src, mod, params, cost_threshold)
end

ssavalue_increment(@nospecialize(body), incr) = body
ssavalue_increment(body::SSAValue, incr) = SSAValue(body.id + incr)
function ssavalue_increment(body::Expr, incr)
    if is_meta_expr(body)
        return body
    end
    for i in 1:length(body.args)
        body.args[i] = ssavalue_increment(body.args[i], incr)
    end
    return body
end
ssavalue_increment(body::PiNode, incr) = PiNode(ssavalue_increment(body.val, incr), body.typ)
function ssavalue_increment(body::PhiNode, incr)
    values = Vector{Any}(undef, length(body.values))
    for i = 1:length(values)
        isassigned(body.values, i) || continue
        values[i] = ssavalue_increment(body.values[i], incr)
    end
    return PhiNode(body.edges, values)
end

function mk_tuplecall(args, sv::OptimizationState)
    e = Expr(:call, TOP_TUPLE, args...)
    e.typ = tuple_tfunc(Tuple{Any[widenconst(exprtype(x, sv.src, sv.mod)) for x in args]...})
    return e
end

function add_slot!(src::CodeInfo, @nospecialize(typ), is_sa::Bool, name::Symbol=COMPILER_TEMP_SYM)
    @assert !isa(typ, Const) && !isa(typ, Conditional)
    id = length(src.slotnames) + 1
    push!(src.slotnames, name)
    push!(src.slottypes, typ)
    push!(src.slotflags, is_sa * SLOT_ASSIGNEDONCE)
    return SlotNumber(id)
end

function is_known_call(e::Expr, @nospecialize(func), src, mod::Module)
    if e.head !== :call
        return false
    end
    f = exprtype(e.args[1], src, mod)
    return isa(f, Const) && f.val === func
end

function is_known_call_p(e::Expr, @nospecialize(pred), src, mod::Module)
    if e.head !== :call
        return false
    end
    f = exprtype(e.args[1], src, mod)
    return (isa(f, Const) && pred(f.val)) || (isType(f) && pred(f.parameters[1]))
end

# fix label numbers to always equal the statement index of the label
function reindex_labels!(body::Vector{Any})
    mapping = get_label_map(body)
    for i = 1:length(body)
        el = body[i]
        # For goto and enter, the statement and the target has to be
        # both reachable or both not.
        if isa(el, LabelNode)
            labelnum = mapping[el.label]
            @assert labelnum !== 0
            body[i] = LabelNode(labelnum)
        elseif isa(el, GotoNode)
            labelnum = mapping[el.label]
            @assert labelnum !== 0
            body[i] = GotoNode(labelnum)
        elseif isa(el, Expr)
            if el.head === :gotoifnot
                labelnum = mapping[el.args[2]::Int]
                @assert labelnum !== 0
                el.args[2] = labelnum
            elseif el.head === :enter
                labelnum = mapping[el.args[1]::Int]
                @assert labelnum !== 0
                el.args[1] = labelnum
            elseif el.head === :(=)
                if isa(el.args[2], PhiNode)
                    edges = Any[mapping[edge::Int + 1] - 1 for edge in el.args[2].edges]
                    @assert all(x->x >= 0, edges)
                    el.args[2] = PhiNode(convert(Vector{Any}, edges), el.args[2].values)
                end
            end
        end
    end
    if body[end] isa LabelNode
        # we usually have a trailing label for the purposes of phi numbering
        # this can now be deleted also if unused
        if label_counter(body, false) < length(body)
            pop!(body)
        end
    end
end

function reindex_labels!(sv::OptimizationState)
    reindex_labels!(sv.src.code)
end

function return_type(@nospecialize(f), @nospecialize(t))
    params = Params(ccall(:jl_get_tls_world_age, UInt, ()))
    rt = Union{}
    if isa(f, Builtin)
        rt = builtin_tfunction(f, Any[t.parameters...], nothing, params)
        if isa(rt, TypeVar)
            rt = rt.ub
        else
            rt = widenconst(rt)
        end
    else
        for m in _methods(f, t, -1, params.world)
            ty = typeinf_type(m[3], m[1], m[2], true, params)
            ty === nothing && return Any
            rt = tmerge(rt, ty)
            rt === Any && break
        end
    end
    return rt
end
