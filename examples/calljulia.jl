using LLVM, LLVM.Interop

Base.@ccallable Int function myfun(x::Int)
    # function myfun(x::Int)
    x + 1
end

@generated function calljulia(y::Int)

    #####both context works #######################
    # ctx = Context()
    ctx = GlobalContext()
    #############################
    # T_int = LLVM.IntType(sizeof(Int) * 8; ctx=ctx)
    T_int = LLVM.Int64Type(ctx)

    paramtyps = [T_int]
    ret_typ = T_int # returning a Ptr{Cvoid}
    llvmf, _ = create_function(ret_typ, paramtyps)

    mod = LLVM.parent(llvmf)
    intrinsic_typ = LLVM.FunctionType(T_int, paramtyps)
    intrinsic = LLVM.Function(mod, "myfun", intrinsic_typ)
    # println(intrinsic)

    # push!(function_attributes(intrinsic), EnumAttribute("alwaysinline", 0; ctx=GlobalContext()))

    Builder(ctx) do builder
        entry = BasicBlock(llvmf, "entry", ctx=ctx)
        position!(builder, entry)
        val = call!(builder, intrinsic, [parameters(llvmf)[1]])

        ## tmp = myfun(x) + x
        val2 = add!(builder, parameters(llvmf)[1], val, "tmp")

        #return tmp
        ret!(builder, val2)
    end
    # PassManagerBuilder() do pmb
    #     optlevel!(pmb, 3)
    #     inliner!(pmb, 10000)
    #     FunctionPassManager(mod) do fpm
    #         populate!(fpm, pmb)
    #         run!(fpm, llvmf)
    #     end
    # end
    # println(mod)
    call_function(llvmf, Int, Tuple{Int,}, :y)
end

println(calljulia(10))
# @test testjuliainline(10) == 11