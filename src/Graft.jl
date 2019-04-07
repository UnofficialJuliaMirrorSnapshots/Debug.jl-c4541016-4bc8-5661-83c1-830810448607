
#   Debug.Graft:
# ================
# Debug instrumentation of code, and transformation of ASTs to act as if they
# were evaluated inside such code (grafting)

module Graft
using Debug.AST, Debug.Meta, Debug.Analysis, Debug.Runtime
using Compat
import Debug.Meta, Debug.AST.is_emittable
export instrument, graft, @localscope, @notrap


# ---- @localscope: returns the Scope instance for the local scope ------------

type GetLocalScope; end
macro localscope()
    code_analyzed_only(Node(GetLocalScope()),
        "@localscope can only be used within @debug or @debug_analyze")
end


# ---- @notrap: prevents generation of traps in the wrapped code --------------

type NoTrap; end
is_emittable(::Node{NoTrap}) = false
macro notrap(ex)
    # Avoid creating any line number nodes so that the resulting block has
    # exactly two arguments, with Node(NoTrap()) being the first,
    # as expected below
    esc(Expr(:block, Node(NoTrap()), ex))
end


# ---- instrument -------------------------------------------------------------
# Add Scope creation and debug traps to (analyzed) code

type Context
    trap_pred::Function
    trap_ex
    env::Env
    scope_ex
end
Context(c::Context,e::Env) = Context(c.trap_pred,c.trap_ex,e,nothing)

function get_scope_ex(c::Context)
    # Generate a gensym on demand; if c.scope_ex is never used
    # it remains nothing
    c.scope_ex === nothing ? c.scope_ex = gensym("scope") : c.scope_ex
end

function instrument(trap_pred::Function, trap_ex, ex)
    @gensym scope
    ex = instrument(Context(trap_pred,trap_ex,NoEnv(),scope), analyze(ex,true))
    quote
        $scope = $(quot(ModuleScope))(eval)
        $ex
    end
end


function code_getset(sym::Symbol)
    val = gensym(string(sym))
    :( ()->$sym, $val->($sym=$val) )
end
function code_scope(scopesym::Symbol, parent, env::Env, syms)
    pairs = [Expr(:(=>), quot(sym), code_getset(sym)) for sym in syms]
    :(local $scopesym = $(quot(LocalScope))(
        $parent,
        $(Expr(:typed_dict,
               :($(quot(Symbol))=>$(quot(@compat(Tuple{Function,Function})))), pairs...)),
        $(quot(env))
    ))
end


code_trap(c::Context, node) = Expr(:call, c.trap_ex, quot(node), get_scope_ex(c))
code_trap_if(c::Context,node) = c.trap_pred(node) ? code_trap(c,node) : nothing

function instrument(c::Context, node::Node)
    if isa(node.state, Rhs) && !is_in_type(node) && c.trap_pred(node)
        Expr(:block, code_trap(c, node), instrument_node(c, node))
    else
        instrument_node(c, node)
    end
end

if VERSION >= v"0.4.0-dev"
    code_enterleave(::Void, ex, ::Void) = ex
    code_enterleave(enter,  ex, ::Void) = quote; $enter; $ex; end
    code_enterleave(::Void, ex, leave) = :(try $ex; finally $leave; end)
else
    code_enterleave(::Nothing, ex, ::Nothing) = ex
    code_enterleave(enter,     ex, ::Nothing) = quote; $enter; $ex; end
    code_enterleave(::Nothing, ex, leave) = :(try $ex; finally $leave; end)
end
code_enterleave(enter,     ex, leave) = :(try $enter; $ex; finally $leave; end)

function instrument_node(c::Context, node::Node)
    if !is_emittable(node); return quot(nothing); end
    ex = instrument_args(c, node)
    if is_scope_node(node)
        enter, leave = code_trap_if(c,Enter(node)), code_trap_if(c,Leave(node))
        if is_function(node)
            @assert is_function(ex)
            Expr(ex.head, ex.args[1], code_enterleave(enter,ex.args[2],leave))
        else
            code_enterleave(enter, ex, leave)
        end
    else
        ex
    end
end

never_trap(ex) = false

instrument_args(c::Context, node::Node) = exof(node)
instrument_args(c::Context, ::Node{GetLocalScope}) = get_scope_ex(c)
function instrument_args(c::Context, node::ExNode)
    args = Any[]
    orig_c = c

    # Detect @notrap
    if isblocknode(node) && nargsof(node) == 2 && isa(argof(node, 1), Node{NoTrap})
        old_trap, c.trap_pred = c.trap_pred, never_trap
        result = instrument(c, argof(node, 2))
        c.trap_pred = old_trap
        return result
    end

    if isblocknode(node) && !is(envof(node), c.env)
        # node introduces a scope, see if we need to reify it
        c = Context(c, envof(node))
        node.introduces_scope = true

        for arg in argsof(node); push!(args, instrument(c, arg)); end

        if c.scope_ex !== nothing
            # create new Scope
            syms, e = Set{Symbol}(), envof(node)
            while !is(e, orig_c.env);  union!(syms, e.defined); e = e.parent  end

            unshift!(args, code_scope(c.scope_ex, get_scope_ex(orig_c), envof(node), syms))
        end
    else
        for arg in argsof(node); push!(args, instrument(c, arg)); end
    end

    Expr(headof(node), args...)
end


# ---- graft ------------------------------------------------------------------
# Rewrite an (analyzed) AST to work as if it were inside
# the given scope, when evaluated in global scope.
# Replaces reads and writes to variables from that scope
# with getter/setter calls.

graft(env::Env, scope::Scope, ex) = rawgraft(scope, analyze(env, ex, false))
graft(scope::Scope, ex) =           graft(child(NoEnv()), scope, ex)


rawgraft(s::LocalScope, ex)         = ex
rawgraft(s::LocalScope, node::Node) = exof(node)
function rawgraft(s::LocalScope, ex::SymNode)
    sym = exof(ex)
    (haskey(s,sym) && !haskey(envof(ex),sym)) ? Expr(:call,quot(getter(s,sym))) : sym
end
function rawgraft(s::LocalScope, ex::Ex)
    head, args = headof(ex), argsof(ex)
    if head == :(=)
        lhs, rhs = args
        if isa(lhs, SymNode)             # assignment to symbol
            rhs = rawgraft(s, rhs)
            sym = exof(lhs)
            if haskey(envof(lhs), sym) || !(sym in s.env.assigned); return :($sym = $rhs)
            elseif haskey(s, sym);   return Expr(:call, quot(setter(s,sym)), rhs)
            else; error("No setter in scope found for $(sym)!")
            end
        elseif is_expr(lhs, :tuple)  # assignment to tuple
            tup = Node(Plain(gensym("tuple"))) # don't recurse into tup
            return rawgraft(s, Expr(:block,
                 :($tup  = $rhs    ),
                [:($dest = $tup[$k]) for (k,dest)=enumerate(argsof(lhs))]...))
        elseif is_expr(lhs, [:ref, :.]) || isa(lhs, PLeaf)# need no lhs rewrite
        else error("graft: not implemented: $ex")
        end
    elseif haskey(Analysis.updating_ops, head) && isa(args[1], SymNode)
        # x+=y ==> x=x+y etc.
        op = Analysis.updating_ops[head]
        return rawgraft(s, :( $(args[1]) = ($op)($(args[1]), $(args[2])) ))
    end
    Expr(head, [rawgraft(s,arg) for arg in args]...)
end

end # module
