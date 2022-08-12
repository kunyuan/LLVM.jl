mutable struct CodeGen
    ctx::LLVM.Context
    builder::LLVM.Builder
    current_scope::CurrentScope
    mod::LLVM.Module

    CodeGen(ctx::LLVM.Context) =
        new(
            ctx,
            #TheContext是一个不透明的对象，拥有许多核心LLVM数据结构，例如类型和常量值表。我们不需要详细了解它，我们只需要一个实例就可以传递到需要它的API中。
            LLVM.Builder(ctx),
            #Builder对象是一个辅助对象，可以轻松生成LLVM指令。 IRBuilder类模板的实例跟踪插入指令的当前位置，并具有创建新指令的方法。
            CurrentScope(),
            LLVM.Module("KaleidoscopeModule"; ctx),
            #TheModule是一个LLVM结构体，包含函数和全局变量。在许多方面，它是LLVM IR用于包含代码的顶级结构。它将拥有我们生成的所有IR的内存，这就是codegen（）方法返回原始的value*而不是unique_ptr <Value>的原因。
        )
end

current_scope(cg::CodeGen) = cg.current_scope
function new_scope(f, cg::CodeGen)
    open_scope!(current_scope(cg))
    f()
    pop!(current_scope(cg))
end
Base.show(io::IO, cg::CodeGen) = print(io, "CodeGen")

function create_entry_block_allocation(cg::CodeGen, fn::LLVM.Function, varname::String)
    local alloc
    LLVM.@dispose builder = LLVM.Builder(cg.ctx) begin
        # Set the builder at the start of the function
        entry_block = LLVM.entry(fn)
        if isempty(LLVM.instructions(entry_block))
            LLVM.position!(builder, entry_block)
        else
            LLVM.position!(builder, first(LLVM.instructions(entry_block)))
        end
        alloc = LLVM.alloca!(builder, LLVM.DoubleType(cg.ctx), varname)
    end
    return alloc
end

function codegen(cg::CodeGen, expr::NumberExprAST)
    return LLVM.ConstantFP(LLVM.DoubleType(cg.ctx), expr.val)
end

function codegen(cg::CodeGen, expr::VariableExprAST)
    V = get(current_scope(cg), expr.name, nothing)
    V == nothing && error("did not find variable $(expr.name)")
    return LLVM.load!(cg.builder, V, expr.name)
end

function codegen(cg::CodeGen, expr::BinaryExprAST)
    if expr.op == Kinds.EQUAL
        var = expr.lhs
        if !(var isa VariableExprAST)
            error("destination of '=' must be a variable")
        end
        R = codegen(cg, expr.rhs)
        V = get(current_scope(cg), var.name, nothing)
        V == nothing && error("unknown variable name $(var.name)")
        LLVM.store!(cg.builder, R, V)
        return R
    end
    L = codegen(cg, expr.lhs)
    R = codegen(cg, expr.rhs)

    if expr.op == Kinds.PLUS
        return LLVM.fadd!(cg.builder, L, R, "addtmp")
        #如果上述代码创建了多个"addtmp"变量，LLVM会给每一个提供一个独一无二的数字后缀增量
    elseif expr.op == Kinds.MINUS
        return LLVM.fsub!(cg.builder, L, R, "subtmp")
    elseif expr.op == Kinds.STAR
        return LLVM.fmul!(cg.builder, L, R, "multmp")
    elseif expr.op == Kinds.SLASH
        return LLVM.fdiv!(cg.builder, L, R, "divtmp")
    elseif expr.op == Kinds.LESS
        #LLVM指示了fcmp指令将总是返回一个'i1'值(一个二进制位的整型)'.
        # 问题是K语言希望值是0.0或者1.0， 为了获取这些语义，我们将fcmp指令和uitofp指令结合起来使用。
        # 这条指令会通过将输入视为一个无符号值来将输入的整数转换为一个浮点数。
        # 相比之下，如果我们使用sitofp指令，K语言的'<'操作符将基于不同的入参返回0.0和-1.0
        # https://zhuanlan.zhihu.com/p/461997653
        L = LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOLT, L, R, "cmptmp")
        return LLVM.uitofp!(cg.builder, L, LLVM.DoubleType(cg.ctx), "booltmp")
    elseif expr.op == Kinds.GREATER
        L = LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOGT, L, R, "cmptmp")
        return LLVM.uitofp!(cg.builder, L, LLVM.DoubleType(cg.ctx), "booltmp")
    else
        error("Unhandled binary operator $(expr.op)")
    end
end

function codegen(cg::CodeGen, expr::CallExprAST)
    if !haskey(LLVM.functions(cg.mod), expr.callee)
        error("encountered undeclared function $(expr.callee)")
    end
    func = LLVM.functions(cg.mod)[expr.callee]

    if length(LLVM.parameters(func)) != length(expr.args)
        error("number of parameters mismatch")
    end

    args = LLVM.Value[]
    for v in expr.args
        push!(args, codegen(cg, v))
    end

    return LLVM.call!(cg.builder, func, args, "calltmp")
end

function codegen(cg::CodeGen, expr::PrototypeAST)
    #原型用来生成函数体和外部函数定义
    #首先这个函数返回一个"Function*"而不是一个"Value*"。
    #因为一个原型其实是描述了一个函数的外部接口(而不是通过一个表达式计算出的值)，所以生成代码时返回一个LLVM Function对象更为合理。
    if haskey(LLVM.functions(cg.mod), expr.name)
        error("existing function exists")
    end
    args = [LLVM.DoubleType(cg.ctx) for i in 1:length(expr.args)]
    func_type = LLVM.FunctionType(LLVM.DoubleType(cg.ctx), args)
    func = LLVM.Function(cg.mod, expr.name, func_type)
    #上面最后一行才实际创建了对应原型的函数IR。
    #这里指定了函数类型，链接形式和要插入的模块。
    #传入的名称是用户指定的名称：当TheModule指定时，此名称已经在TheModules的符号表中已经注册了。

    LLVM.linkage!(func, LLVM.API.LLVMExternalLinkage)
    # external linkage标识这个函数可能被定义在当前模块之外并且/或它可以被外部模块所调用。

    for (i, param) in enumerate(LLVM.parameters(func))
        LLVM.name!(param, expr.args[i])
    end
    return func
end

function codegen(cg::CodeGen, expr::FunctionAST)
    # create new function...
    the_function = codegen(cg, expr.proto)

    #LLVM中的基本块是定义控制流图的重要部分。在我们没有任何控制流之前，我们的函数将仅仅包含一个块
    entry = LLVM.BasicBlock(the_function, "entry"; cg.ctx)
    #创建了一个插入到TheFunction的基本块，名称为entry
    LLVM.position!(cg.builder, entry)
    #告诉Builder新的指令应该被插入在新的基本块后面

    new_scope(cg) do
        for (i, param) in enumerate(LLVM.parameters(the_function))
            argname = expr.proto.args[i]
            alloc = create_entry_block_allocation(cg, the_function, argname)
            LLVM.store!(cg.builder, param, alloc)
            current_scope(cg)[argname] = alloc
        end

        body = codegen(cg, expr.body)
        # 调用根表达式的codegen()方法。即函数内部的具体指令。
        LLVM.ret!(cg.builder, body)
        # 创建一个LLVM返回指令，用于完成这个函数
        LLVM.verify(the_function)
        # 一旦函数构建完成，我们调用LLVM提供的verifyFunction函数。这个函数会在生成的代码上执行各种一致性检查，去确保你的编译器正确运行。使用它非常重要，它可以捕捉大量的漏洞
    end

    #然而这段代码有个bug：如果FunctionAST::codegen()方法找到了一个已经存在的IR函数，它并不会根据用户定义的原型去验证它。
    # 这就意味着之前的'extern'定义将比函数自身的定义优先级更高，这样有可能导致代码生成失败。例如函数的参数名不一致。根据不同的思路可以有很多种方法去修正这个bug，例如：
    # extern foo(a);     # ok, defines foo.
    # def foo(b) b;      # Error: Unknown variable name. (decl using 'a' takes precedence).

    return the_function
end

function codegen(cg::CodeGen, expr::IfExprAST)
    func = LLVM.parent(LLVM.position(cg.builder))
    then = LLVM.BasicBlock(func, "then"; cg.ctx)
    elsee = LLVM.BasicBlock(func, "else"; cg.ctx)
    merge = LLVM.BasicBlock(func, "ifcont"; cg.ctx)

    local phi
    new_scope(cg) do
        # if
        cond = codegen(cg, expr.cond)
        zero = LLVM.ConstantFP(LLVM.DoubleType(cg.ctx), 0.0)
        condv = LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealONE, cond, zero, "ifcond")
        LLVM.br!(cg.builder, condv, then, elsee)

        # then
        LLVM.position!(cg.builder, then)
        thencg = codegen(cg, expr.then)
        LLVM.br!(cg.builder, merge)
        then_block = position(cg.builder)

        # else
        LLVM.position!(cg.builder, elsee)
        elsecg = codegen(cg, expr.elsee)
        LLVM.br!(cg.builder, merge)
        else_block = position(cg.builder)

        # merge
        LLVM.position!(cg.builder, merge)
        phi = LLVM.phi!(cg.builder, LLVM.DoubleType(cg.ctx), "iftmp")
        append!(LLVM.incoming(phi), [(thencg, then_block), (elsecg, else_block)])
    end

    return phi
end

function codegen(cg::CodeGen, expr::ForExprAST)
    new_scope(cg) do
        # Allocate loop variable
        startblock = position(cg.builder)
        func = LLVM.parent(startblock)
        alloc = create_entry_block_allocation(cg, func, expr.varname)
        current_scope(cg)[expr.varname] = alloc
        start = codegen(cg, expr.start)
        LLVM.store!(cg.builder, start, alloc)

        # Loop block
        loopblock = LLVM.BasicBlock(func, "loop"; cg.ctx)
        LLVM.br!(cg.builder, loopblock)
        LLVM.position!(cg.builder, loopblock)

        # Code for loop block
        codegen(cg, expr.body)
        step = codegen(cg, expr.step)
        endd = codegen(cg, expr.endd)

        curvar = LLVM.load!(cg.builder, alloc, expr.varname)
        nextvar = LLVM.fadd!(cg.builder, curvar, step, "nextvar")
        LLVM.store!(cg.builder, nextvar, alloc)

        endd = LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealONE, endd,
            LLVM.ConstantFP(LLVM.DoubleType(cg.ctx), 0.0))

        loopendblock = position(cg.builder)
        afterblock = LLVM.BasicBlock(func, "afterloop"; cg.ctx)

        LLVM.br!(cg.builder, endd, loopblock, afterblock)
        LLVM.position!(cg.builder, afterblock)
    end

    # loops return 0.0 for now
    return LLVM.ConstantFP(LLVM.DoubleType(cg.ctx), 0.0)
end

function codegen(cg::CodeGen, expr::VarExprAST)
    local initval
    for (varname, init) in expr.varnames
        initval = codegen(cg, init)
        local V
        if isglobalscope(current_scope(cg))
            V = LLVM.GlobalVariable(cg.mod, LLVM.DoubleType(cg.ctx), varname)
            LLVM.initializer!(V, initval)
        else
            func = LLVM.parent(LLVM.position(cg.builder))
            V = create_entry_block_allocation(cg, func, varname)
            LLVM.store!(cg.builder, initval, V)
        end
        current_scope(cg)[varname] = V
    end
    return initval
end

function codegen(cg::CodeGen, block::BlockExprAST)
    local v
    new_scope(cg) do
        for expr in block.exprs
            v = codegen(cg, expr)
        end
    end
    return v
end
