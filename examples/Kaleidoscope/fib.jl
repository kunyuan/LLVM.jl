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

ctx = Context()

#you may also use the default context of the current julia session
# ctx = GlobalContext()

mod = Kaleidoscope.generate_IR(source; ctx=ctx)
Kaleidoscope.optimize!(mod)

########### to run in julia ###########################
engine = Interpreter(mod)
f = LLVM.functions(mod)["fib"] #get the fib function
args = [GenericValue(LLVM.DoubleType(LLVM.context(mod)), 10.0),]
#take 0.000151 seconds (4 allocations: 176 bytes)
# slow!
res = LLVM.run(engine, f, args)
res_jl = convert(Float64, res, LLVM.DoubleType(LLVM.context(mod)))
println(res_jl)


############ make the function callable from julia ##############

@eval call_fib(x) = $(call_function(f, Float64, Tuple{Float64,}, :x))
#take 0.000002 seconds, no allocations
# very fast!
res2 = call_fib(10.0)
println(res2)