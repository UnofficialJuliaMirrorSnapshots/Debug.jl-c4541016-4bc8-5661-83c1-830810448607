isdefined(Main, :__precompile__) && __precompile__(true)

module Debug

include("AST.jl")
include("Meta.jl")
include("Analysis.jl")
include("Runtime.jl")
include("Graft.jl")
include("Eval.jl")
include("Flow.jl")
include("UI.jl")
using Debug.AST, Debug.Meta, Debug.Analysis, Debug.Graft, Debug.Eval
using Debug.Flow, Debug.UI

# It seems that @instrument has to be exported in order not to be deleted
export @debug, @bp, @instrument, @localscope, debug_eval, @debug_analyze, @notrap

is_trap(::Event)    = false
is_trap(::LocNode)  = false
is_trap(node::Node) = isblocknode(parentof(node))

macro debug(ex)
    code_debug(UI.instrument(ex))
end
never_trap(ex) = false
macro debug_analyze(ex)
    code_debug(instrument(never_trap, nothing, ex))
end
macro instrument(trap_ex, ex)
    @gensym trap_var
    code_debug(quote
        const $trap_var = $trap_ex
        $(instrument(is_trap, trap_var, ex))
    end)
end

function code_debug(ex)
    globalvar = gensym("globalvar")
    esc(quote
        $globalvar = nothing
        if !isdefined($(quot(globalvar)))
            error("@debug: must be applied in global (i.e. module) scope!")
        end
        $ex
    end)
end

end # module
