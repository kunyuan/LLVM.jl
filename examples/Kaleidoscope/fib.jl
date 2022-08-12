source = "
def fib(x) {
    if x < 3 then
        1
    else
        fib(x-1) + fib(x-2)
  }
"

using LLVM
using LLVM.Interop

include("./Kaleidoscope.jl")

#you may also use the default context of the current julia session
# ctx = GlobalContext()

@dispose ctx = Context() begin


    mod = Kaleidoscope.generate_IR(source; ctx=ctx)
    # you can get current context by calling LLVM.context(mod)
    println("IR before optimization: $mod")
    Kaleidoscope.optimize!(mod)
    println("IR after optimization: $mod")

    ########### to run in julia ###########################
    @dispose engine = Interpreter(mod) begin
        f = LLVM.functions(mod)["fib"] #get the fib function
        args = [GenericValue(LLVM.DoubleType(ctx), 10.0),]
        #take 0.000151 seconds (4 allocations: 176 bytes)
        # slow!
        res = LLVM.run(engine, f, args)
        res_jl = convert(Float64, res, LLVM.DoubleType(ctx))
        println(res_jl)

        ############ make the function callable from julia ##############

        push!(function_attributes(f), EnumAttribute("alwaysinline"; ctx))
        @eval call_fib(x) = $(call_function(f, Float64, Tuple{Float64,}, :x))
        #take 0.000002 seconds, no allocations
        # very fast!

        dispose.(args)
        dispose(res)
    end
end

res2 = call_fib(10.0)
println(res2)