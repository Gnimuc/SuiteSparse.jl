# This file is a part of Julia. License is MIT: https://julialang.org/license

module UMFPACK

export UmfpackLU

import Base: (\), getproperty, show, size
using LinearAlgebra
import LinearAlgebra: Factorization, checksquare, det, logabsdet, lu, lu!, ldiv!

using SparseArrays
using SparseArrays: getcolptr
import SparseArrays: nnz

import Serialization: AbstractSerializer, deserialize

import ..increment, ..increment!, ..decrement, ..decrement!

import ..LibSuiteSparse:
    SuiteSparse_long,
    umfpack_dl_defaults,
    umfpack_dl_report_control,
    umfpack_dl_report_info,
    ## Type of solve
    UMFPACK_A,        # Ax=b
    UMFPACK_At,       # adjoint(A)x=b
    UMFPACK_Aat,      # transpose(A)x=b
    UMFPACK_Pt_L,     # adjoint(P)Lx=b
    UMFPACK_L,        # Lx=b
    UMFPACK_Lt_P,     # adjoint(L)Px=b
    UMFPACK_Lat_P,    # transpose(L)Px=b
    UMFPACK_Lt,       # adjoint(L)x=b
    UMFPACK_Lat,      # transpose(L)x=b
    UMFPACK_U_Qt,     # U*adjoint(Q)x=b
    UMFPACK_U,        # Ux=b
    UMFPACK_Q_Ut,     # Q*adjoint(U)x=b
    UMFPACK_Q_Uat,    # Q*transpose(U)x=b
    UMFPACK_Ut,       # adjoint(U)x=b
    UMFPACK_Uat,      # transpose(U)x=b
    ## Sizes of Control and Info arrays for returning information from solver
    UMFPACK_INFO,
    UMFPACK_CONTROL,
    UMFPACK_PRL,
    ## Status codes
    UMFPACK_OK,
    UMFPACK_WARNING_singular_matrix,
    UMFPACK_WARNING_determinant_underflow,
    UMFPACK_WARNING_determinant_overflow,
    UMFPACK_ERROR_out_of_memory,
    UMFPACK_ERROR_invalid_Numeric_object,
    UMFPACK_ERROR_invalid_Symbolic_object,
    UMFPACK_ERROR_argument_missing,
    UMFPACK_ERROR_n_nonpositive,
    UMFPACK_ERROR_invalid_matrix,
    UMFPACK_ERROR_different_pattern,
    UMFPACK_ERROR_invalid_system,
    UMFPACK_ERROR_invalid_permutation,
    UMFPACK_ERROR_internal_error,
    UMFPACK_ERROR_file_IO,
    UMFPACK_ERROR_ordering_failed

struct MatrixIllConditionedException <: Exception
    msg::String
end

function umferror(status::Integer)
    if status==UMFPACK_OK
        return
    elseif status==UMFPACK_WARNING_singular_matrix
        throw(LinearAlgebra.SingularException(0))
    elseif status==UMFPACK_WARNING_determinant_underflow
        throw(MatrixIllConditionedException("the determinant is nonzero but underflowed"))
    elseif status==UMFPACK_WARNING_determinant_overflow
        throw(MatrixIllConditionedException("the determinant overflowed"))
    elseif status==UMFPACK_ERROR_out_of_memory
        throw(OutOfMemoryError())
    elseif status==UMFPACK_ERROR_invalid_Numeric_object
        throw(ArgumentError("invalid UMFPack numeric object"))
    elseif status==UMFPACK_ERROR_invalid_Symbolic_object
        throw(ArgumentError("invalid UMFPack symbolic object"))
    elseif status==UMFPACK_ERROR_argument_missing
        throw(ArgumentError("a required argument to UMFPack is missing"))
    elseif status==UMFPACK_ERROR_n_nonpositive
        throw(ArgumentError("the number of rows or columns of the matrix must be greater than zero"))
    elseif status==UMFPACK_ERROR_invalid_matrix
        throw(ArgumentError("invalid matrix"))
    elseif status==UMFPACK_ERROR_different_pattern
        throw(ArgumentError("pattern of the matrix changed"))
    elseif status==UMFPACK_ERROR_invalid_system
        throw(ArgumentError("invalid sys argument provided to UMFPack solver"))
    elseif status==UMFPACK_ERROR_invalid_permutation
        throw(ArgumentError("invalid permutation"))
    elseif status==UMFPACK_ERROR_file_IO
        throw(ErrorException("error saving / loading UMFPack decomposition"))
    elseif status==UMFPACK_ERROR_ordering_failed
        throw(ErrorException("the ordering method failed"))
    elseif status==UMFPACK_ERROR_internal_error
        throw(ErrorException("an internal error has occurred, of unknown cause"))
    else
        throw(ErrorException("unknown UMFPack error code: $status"))
    end
end

macro isok(A)
    :(umferror($(esc(A))))
end

# check the size of SuiteSparse_long
if sizeof(SuiteSparse_long) == 4
    const UmfpackIndexTypes = (:Int32,)
    const UMFITypes = Int32
else
    const UmfpackIndexTypes = (:Int32, :Int64)
    const UMFITypes = Union{Int32, Int64}
end

const UMFVTypes = Union{Float64,ComplexF64}

## UMFPACK

# the control and info arrays
const umf_ctrl = Vector{Float64}(undef, UMFPACK_CONTROL)
umfpack_dl_defaults(umf_ctrl)
const umf_info = Vector{Float64}(undef, UMFPACK_INFO)

function show_umf_ctrl(level::Real = 2.0)
    old_prt::Float64 = umf_ctrl[1]
    umf_ctrl[1] = Float64(level)
    umfpack_dl_report_control(umf_ctrl)
    umf_ctrl[1] = old_prt
end

function show_umf_info(level::Real = 2.0)
    old_prt::Float64 = umf_ctrl[1]
    umf_ctrl[1] = Float64(level)
    umfpack_dl_report_info(umf_ctrl, umf_info)
    umf_ctrl[1] = old_prt
end

## Should this type be immutable?
mutable struct UmfpackLU{Tv<:UMFVTypes,Ti<:UMFITypes} <: Factorization{Tv}
    symbolic::Ptr{Cvoid}
    numeric::Ptr{Cvoid}
    m::Int
    n::Int
    colptr::Vector{Ti}                  # 0-based column pointers
    rowval::Vector{Ti}                  # 0-based row indices
    nzval::Vector{Tv}
    status::Int
end

Base.adjoint(F::UmfpackLU) = Adjoint(F)
Base.transpose(F::UmfpackLU) = Transpose(F)

"""
    lu(A::SparseMatrixCSC; check = true) -> F::UmfpackLU

Compute the LU factorization of a sparse matrix `A`.

For sparse `A` with real or complex element type, the return type of `F` is
`UmfpackLU{Tv, Ti}`, with `Tv` = [`Float64`](@ref) or `ComplexF64` respectively and
`Ti` is an integer type ([`Int32`](@ref) or [`Int64`](@ref)).

When `check = true`, an error is thrown if the decomposition fails.
When `check = false`, responsibility for checking the decomposition's
validity (via [`issuccess`](@ref)) lies with the user.

The individual components of the factorization `F` can be accessed by indexing:

| Component | Description                         |
|:----------|:------------------------------------|
| `L`       | `L` (lower triangular) part of `LU` |
| `U`       | `U` (upper triangular) part of `LU` |
| `p`       | right permutation `Vector`          |
| `q`       | left permutation `Vector`           |
| `Rs`      | `Vector` of scaling factors         |
| `:`       | `(L,U,p,q,Rs)` components           |

The relation between `F` and `A` is

`F.L*F.U == (F.Rs .* A)[F.p, F.q]`

`F` further supports the following functions:

- [`\\`](@ref)
- [`cond`](@ref)
- [`det`](@ref)

!!! note
    `lu(A::SparseMatrixCSC)` uses the UMFPACK library that is part of
    SuiteSparse. As this library only supports sparse matrices with [`Float64`](@ref) or
    `ComplexF64` elements, `lu` converts `A` into a copy that is of type
    `SparseMatrixCSC{Float64}` or `SparseMatrixCSC{ComplexF64}` as appropriate.
"""
function lu(S::SparseMatrixCSC{<:UMFVTypes,<:UMFITypes}; check::Bool = true)
    zerobased = getcolptr(S)[1] == 0
    res = UmfpackLU(C_NULL, C_NULL, size(S, 1), size(S, 2),
                    zerobased ? copy(getcolptr(S)) : decrement(getcolptr(S)),
                    zerobased ? copy(rowvals(S)) : decrement(rowvals(S)),
                    copy(nonzeros(S)), 0)
    finalizer(umfpack_free_symbolic, res)
    umfpack_numeric!(res)
    check && (issuccess(res) || throw(LinearAlgebra.SingularException(0)))
    return res
end
lu(A::SparseMatrixCSC{<:Union{Float16,Float32},Ti};
   check::Bool = true) where {Ti<:UMFITypes} =
    lu(convert(SparseMatrixCSC{Float64,Ti}, A); check = check)
lu(A::SparseMatrixCSC{<:Union{ComplexF16,ComplexF32},Ti};
   check::Bool = true) where {Ti<:UMFITypes} =
    lu(convert(SparseMatrixCSC{ComplexF64,Ti}, A); check = check)
lu(A::Union{SparseMatrixCSC{T},SparseMatrixCSC{Complex{T}}};
   check::Bool = true) where {T<:AbstractFloat} =
    throw(ArgumentError(string("matrix type ", typeof(A), "not supported. ",
    "Try lu(convert(SparseMatrixCSC{Float64/ComplexF64,Int}, A)) for ",
    "sparse floating point LU using UMFPACK or lu(Array(A)) for generic ",
    "dense LU.")))
lu(A::SparseMatrixCSC; check::Bool = true) = lu(float(A); check = check)

"""
    lu!(F::UmfpackLU, A::SparseMatrixCSC; check=true) -> F::UmfpackLU

Compute the LU factorization of a sparse matrix `A`, reusing the symbolic
factorization of an already existing LU factorization stored in `F`. The
sparse matrix `A` must have an identical nonzero pattern as the matrix used
to create the LU factorization `F`, otherwise an error is thrown.

When `check = true`, an error is thrown if the decomposition fails.
When `check = false`, responsibility for checking the decomposition's
validity (via [`issuccess`](@ref)) lies with the user.

!!! note
    `lu!(F::UmfpackLU, A::SparseMatrixCSC)` uses the UMFPACK library that is part of
    SuiteSparse. As this library only supports sparse matrices with [`Float64`](@ref) or
    `ComplexF64` elements, `lu!` converts `A` into a copy that is of type
    `SparseMatrixCSC{Float64}` or `SparseMatrixCSC{ComplexF64}` as appropriate.

!!! compat "Julia 1.5"
    `lu!` for `UmfpackLU` requires at least Julia 1.5.

# Examples
```jldoctest
julia> A = sparse(Float64[1.0 2.0; 0.0 3.0]);

julia> F = lu(A);

julia> B = sparse(Float64[1.0 1.0; 0.0 1.0]);

julia> lu!(F, B);

julia> F \\ ones(2)
2-element Vector{Float64}:
 0.0
 1.0
```
"""
function lu!(F::UmfpackLU, S::SparseMatrixCSC{<:UMFVTypes,<:UMFITypes}; check::Bool=true)
    zerobased = getcolptr(S)[1] == 0
    F.m = size(S, 1)
    F.n = size(S, 2)
    F.colptr = zerobased ? copy(getcolptr(S)) : decrement(getcolptr(S))
    F.rowval = zerobased ? copy(rowvals(S)) : decrement(rowvals(S))
    F.nzval = copy(nonzeros(S))

    umfpack_numeric!(F, reuse_numeric = false)
    check && (issuccess(F) || throw(LinearAlgebra.SingularException(0)))
    return F
end
lu!(F::UmfpackLU, A::SparseMatrixCSC{<:Union{Float16,Float32},Ti};
   check::Bool = true) where {Ti<:UMFITypes} =
    lu!(F, convert(SparseMatrixCSC{Float64,Ti}, A); check = check)
lu!(F::UmfpackLU, A::SparseMatrixCSC{<:Union{ComplexF16,ComplexF32},Ti};
   check::Bool = true) where {Ti<:UMFITypes} =
    lu!(F, convert(SparseMatrixCSC{ComplexF64,Ti}, A); check = check)
lu!(F::UmfpackLU, A::Union{SparseMatrixCSC{T},SparseMatrixCSC{Complex{T}}};
   check::Bool = true) where {T<:AbstractFloat} =
    throw(ArgumentError(string("matrix type ", typeof(A), "not supported.")))
lu!(F::UmfpackLU, A::SparseMatrixCSC; check::Bool = true) = lu!(F, float(A); check = check)

size(F::UmfpackLU) = (F.m, F.n)
function size(F::UmfpackLU, dim::Integer)
    if dim < 1
        throw(ArgumentError("size: dimension $dim out of range"))
    elseif dim == 1
        return Int(F.m)
    elseif dim == 2
        return Int(F.n)
    else
        return 1
    end
end

function show(io::IO, mime::MIME{Symbol("text/plain")}, F::UmfpackLU)
    if F.numeric != C_NULL
        if issuccess(F)
            summary(io, F); println(io)
            println(io, "L factor:")
            show(io, mime, F.L)
            println(io, "\nU factor:")
            show(io, mime, F.U)
        else
            print(io, "Failed factorization of type $(typeof(F))")
        end
    end
end

function deserialize(s::AbstractSerializer, t::Type{UmfpackLU{Tv,Ti}}) where {Tv,Ti}
    symbolic = deserialize(s)
    numeric  = deserialize(s)
    m        = deserialize(s)
    n        = deserialize(s)
    colptr   = deserialize(s)
    rowval   = deserialize(s)
    nzval    = deserialize(s)
    status   = deserialize(s)
    obj      = UmfpackLU{Tv,Ti}(symbolic, numeric, m, n, colptr, rowval, nzval, status)

    finalizer(umfpack_free_symbolic, obj)

    return obj
end

# compute the sign/parity of a permutation
function _signperm(p)
    n = length(p)
    result = 0
    todo = trues(n)
    while any(todo)
        k = findfirst(todo)
        todo[k] = false
        result += 1 # increment element count
        j = p[k]
        while j != k
            result += 1 # increment element count
            todo[j] = false
            j = p[j]
        end
        result += 1 # increment cycle count
    end
    return ifelse(isodd(result), -1, 1)
end

## Wrappers for UMFPACK functions

# generate the name of the C function according to the value and integer types
umf_nm(nm,Tv,Ti) = "umfpack_" * (Tv === :Float64 ? "d" : "z") * (Ti === :Int64 ? "l_" : "i_") * nm

for itype in UmfpackIndexTypes
    sym_r = umf_nm("symbolic", :Float64, itype)
    sym_c = umf_nm("symbolic", :ComplexF64, itype)
    num_r = umf_nm("numeric", :Float64, itype)
    num_c = umf_nm("numeric", :ComplexF64, itype)
    sol_r = umf_nm("solve", :Float64, itype)
    sol_c = umf_nm("solve", :ComplexF64, itype)
    det_r = umf_nm("get_determinant", :Float64, itype)
    det_z = umf_nm("get_determinant", :ComplexF64, itype)
    lunz_r = umf_nm("get_lunz", :Float64, itype)
    lunz_z = umf_nm("get_lunz", :ComplexF64, itype)
    get_num_r = umf_nm("get_numeric", :Float64, itype)
    get_num_z = umf_nm("get_numeric", :ComplexF64, itype)
    @eval begin
        function umfpack_symbolic!(U::UmfpackLU{Float64,$itype})
            if U.symbolic != C_NULL return U end
            tmp = Vector{Ptr{Cvoid}}(undef, 1)
            @isok ccall(($sym_r, :libumfpack), $itype,
                        ($itype, $itype, Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Cvoid},
                         Ptr{Float64}, Ptr{Float64}),
                        U.m, U.n, U.colptr, U.rowval, U.nzval, tmp,
                        umf_ctrl, umf_info)
            U.symbolic = tmp[1]
            return U
        end
        function umfpack_symbolic!(U::UmfpackLU{ComplexF64,$itype})
            if U.symbolic != C_NULL return U end
            tmp = Vector{Ptr{Cvoid}}(undef, 1)
            @isok ccall(($sym_c, :libumfpack), $itype,
                        ($itype, $itype, Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Float64}, Ptr{Cvoid},
                         Ptr{Float64}, Ptr{Float64}),
                        U.m, U.n, U.colptr, U.rowval, real(U.nzval), imag(U.nzval), tmp,
                        umf_ctrl, umf_info)
            U.symbolic = tmp[1]
            return U
        end
        function umfpack_numeric!(U::UmfpackLU{Float64,$itype}; reuse_numeric = true)
            if (reuse_numeric && U.numeric != C_NULL) return U end
            if U.symbolic == C_NULL umfpack_symbolic!(U) end
            tmp = Vector{Ptr{Cvoid}}(undef, 1)
            status = ccall(($num_r, :libumfpack), $itype,
                           (Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Cvoid}, Ptr{Cvoid},
                            Ptr{Float64}, Ptr{Float64}),
                           U.colptr, U.rowval, U.nzval, U.symbolic, tmp,
                           umf_ctrl, umf_info)
            U.status = status
            if status != UMFPACK_WARNING_singular_matrix
                umferror(status)
            end
            U.numeric != C_NULL && umfpack_free_numeric(U)
            U.numeric = tmp[1]
            return U
        end
        function umfpack_numeric!(U::UmfpackLU{ComplexF64,$itype}; reuse_numeric = true)
            if (reuse_numeric && U.numeric != C_NULL) return U end
            if U.symbolic == C_NULL umfpack_symbolic!(U) end
            tmp = Vector{Ptr{Cvoid}}(undef, 1)
            status = ccall(($num_c, :libumfpack), $itype,
                           (Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Float64}, Ptr{Cvoid}, Ptr{Cvoid},
                            Ptr{Float64}, Ptr{Float64}),
                           U.colptr, U.rowval, real(U.nzval), imag(U.nzval), U.symbolic, tmp,
                           umf_ctrl, umf_info)
            U.status = status
            if status != UMFPACK_WARNING_singular_matrix
                umferror(status)
            end
            U.numeric != C_NULL && umfpack_free_numeric(U)
            U.numeric = tmp[1]
            return U
        end
        function solve!(x::StridedVector{Float64}, lu::UmfpackLU{Float64,$itype}, b::StridedVector{Float64}, typ::Integer)
            if x === b
                throw(ArgumentError("output array must not be aliased with input array"))
            end
            if stride(x, 1) != 1 || stride(b, 1) != 1
                throw(ArgumentError("in and output vectors must have unit strides"))
            end
            umfpack_numeric!(lu)
            (size(b,1) == lu.m) && (size(b) == size(x)) || throw(DimensionMismatch())
            @isok ccall(($sol_r, :libumfpack), $itype,
                ($itype, Ptr{$itype}, Ptr{$itype}, Ptr{Float64},
                 Ptr{Float64}, Ptr{Float64}, Ptr{Cvoid}, Ptr{Float64},
                 Ptr{Float64}),
                typ, lu.colptr, lu.rowval, lu.nzval,
                x, b, lu.numeric, umf_ctrl,
                umf_info)
            return x
        end
        function solve!(x::StridedVector{ComplexF64}, lu::UmfpackLU{ComplexF64,$itype}, b::StridedVector{ComplexF64}, typ::Integer)
            if x === b
                throw(ArgumentError("output array must not be aliased with input array"))
            end
            if stride(x, 1) != 1 || stride(b, 1) != 1
                throw(ArgumentError("in and output vectors must have unit strides"))
            end
            umfpack_numeric!(lu)
            (size(b, 1) == lu.m) && (size(b) == size(x)) || throw(DimensionMismatch())
            n = size(b, 1)
            @isok ccall(($sol_c, :libumfpack), $itype,
                        ($itype, Ptr{$itype}, Ptr{$itype}, Ptr{Float64},
                         Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64},
                         Ptr{Float64}, Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}),
                        typ, lu.colptr, lu.rowval, lu.nzval,
                        C_NULL, x, C_NULL, b,
                        C_NULL, lu.numeric, umf_ctrl, umf_info)
            return x
        end
        function det(lu::UmfpackLU{Float64,$itype})
            mx = Ref{Float64}()
            @isok ccall(($det_r,:libumfpack), $itype,
                           (Ptr{Float64},Ptr{Float64},Ptr{Cvoid},Ptr{Float64}),
                           mx, C_NULL, lu.numeric, umf_info)
            mx[]
        end
        function det(lu::UmfpackLU{ComplexF64,$itype})
            mx = Ref{Float64}()
            mz = Ref{Float64}()
            @isok ccall(($det_z,:libumfpack), $itype,
                        (Ptr{Float64},Ptr{Float64},Ptr{Float64},Ptr{Cvoid},Ptr{Float64}),
                        mx, mz, C_NULL, lu.numeric, umf_info)
            complex(mx[], mz[])
        end
        function logabsdet(F::UmfpackLU{T, $itype}) where {T<:Union{Float64,ComplexF64}} # return log(abs(det)) and sign(det)
            n = checksquare(F)
            issuccess(F) || return log(zero(real(T))), zero(T)
            U = F.U
            Rs = F.Rs
            p = F.p
            q = F.q
            s = _signperm(p)*_signperm(q)*one(real(T))
            P = one(T)
            abs_det = zero(real(T))
            @inbounds for i in 1:n
                dg_ii = U[i, i] / Rs[i]
                P *= sign(dg_ii)
                abs_det += log(abs(dg_ii))
            end
            return abs_det, s * P
        end
        function umf_lunz(lu::UmfpackLU{Float64,$itype})
            lnz = Ref{$itype}()
            unz = Ref{$itype}()
            n_row = Ref{$itype}()
            n_col = Ref{$itype}()
            nz_diag = Ref{$itype}()
            @isok ccall(($lunz_r,:libumfpack), $itype,
                           (Ptr{$itype},Ptr{$itype},Ptr{$itype},Ptr{$itype},Ptr{$itype},Ptr{Cvoid}),
                           lnz, unz, n_row, n_col, nz_diag, lu.numeric)
            (lnz[], unz[], n_row[], n_col[], nz_diag[])
        end
        function umf_lunz(lu::UmfpackLU{ComplexF64,$itype})
            lnz = Ref{$itype}()
            unz = Ref{$itype}()
            n_row = Ref{$itype}()
            n_col = Ref{$itype}()
            nz_diag = Ref{$itype}()
            @isok ccall(($lunz_z,:libumfpack), $itype,
                           (Ptr{$itype},Ptr{$itype},Ptr{$itype},Ptr{$itype},Ptr{$itype},Ptr{Cvoid}),
                           lnz, unz, n_row, n_col, nz_diag, lu.numeric)
            (lnz[], unz[], n_row[], n_col[], nz_diag[])
        end
        function getproperty(lu::UmfpackLU{Float64, $itype}, d::Symbol)
            if d === :L
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Lp = Vector{$itype}(undef, n_row + 1)
                # L is returned in CSR (compressed sparse row) format
                Lj = Vector{$itype}(undef, lnz)
                Lx = Vector{Float64}(undef, lnz)
                @isok ccall(($get_num_r, :libumfpack), $itype,
                            (Ptr{$itype}, Ptr{$itype}, Ptr{Float64},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            Lp, Lj, Lx,
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return copy(transpose(SparseMatrixCSC(min(n_row, n_col), n_row,
                                                      increment!(Lp), increment!(Lj), Lx)))
            elseif d === :U
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Up = Vector{$itype}(undef, n_col + 1)
                Ui = Vector{$itype}(undef, unz)
                Ux = Vector{Float64}(undef, unz)
                @isok ccall(($get_num_r, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{$itype}, Ptr{$itype}, Ptr{Float64},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL,
                            Up, Ui, Ux,
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return  SparseMatrixCSC(min(n_row, n_col), n_col, increment!(Up),
                                        increment!(Ui), Ux)
            elseif d === :p
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                P  = Vector{$itype}(undef, n_row)
                @isok ccall(($get_num_r, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{$itype}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL,
                            P, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return increment!(P)
            elseif d === :q
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Q  = Vector{$itype}(undef, n_col)
                @isok ccall(($get_num_r, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{$itype}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, Q, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return increment!(Q)
            elseif d === :Rs
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Rs = Vector{Float64}(undef, n_row)
                @isok ccall(($get_num_r, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Float64}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL,
                            C_NULL, Rs, lu.numeric)
                return Rs
            elseif d === :(:)
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Lp = Vector{$itype}(undef, n_row + 1)
                # L is returned in CSR (compressed sparse row) format
                Lj = Vector{$itype}(undef, lnz)
                Lx = Vector{Float64}(undef, lnz)
                Up = Vector{$itype}(undef, n_col + 1)
                Ui = Vector{$itype}(undef, unz)
                Ux = Vector{Float64}(undef, unz)
                P  = Vector{$itype}(undef, n_row)
                Q  = Vector{$itype}(undef, n_col)
                Rs = Vector{Float64}(undef, n_row)
                @isok ccall(($get_num_r, :libumfpack), $itype,
                            (Ptr{$itype}, Ptr{$itype}, Ptr{Float64},
                             Ptr{$itype}, Ptr{$itype}, Ptr{Float64},
                             Ptr{$itype}, Ptr{$itype}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Float64}, Ptr{Cvoid}),
                            Lp, Lj, Lx,
                            Up, Ui, Ux,
                            P, Q, C_NULL,
                            C_NULL, Rs, lu.numeric)
                return (copy(transpose(SparseMatrixCSC(min(n_row, n_col), n_row,
                                                       increment!(Lp), increment!(Lj),
                                                       Lx))),
                        SparseMatrixCSC(min(n_row, n_col), n_col, increment!(Up),
                                        increment!(Ui), Ux),
                        increment!(P), increment!(Q), Rs)
            else
                return getfield(lu, d)
            end
        end
        function getproperty(lu::UmfpackLU{ComplexF64, $itype}, d::Symbol)
            if d === :L
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Lp = Vector{$itype}(undef, n_row + 1)
                # L is returned in CSR (compressed sparse row) format
                Lj = Vector{$itype}(undef, lnz)
                Lx = Vector{Float64}(undef, lnz)
                Lz = Vector{Float64}(undef, lnz)
                @isok ccall(($get_num_z, :libumfpack), $itype,
                            (Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Float64},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            Lp, Lj, Lx, Lz,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return copy(transpose(SparseMatrixCSC(min(n_row, n_col), n_row,
                                                      increment!(Lp), increment!(Lj),
                                                      complex.(Lx, Lz))))
            elseif d === :U
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Up = Vector{$itype}(undef, n_col + 1)
                Ui = Vector{$itype}(undef, unz)
                Ux = Vector{Float64}(undef, unz)
                Uz = Vector{Float64}(undef, unz)
                @isok ccall(($get_num_z, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Float64},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            Up, Ui, Ux, Uz,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return SparseMatrixCSC(min(n_row, n_col), n_col, increment!(Up),
                                       increment!(Ui), complex.(Ux, Uz))
            elseif d === :p
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                P  = Vector{$itype}(undef, n_row)
                @isok ccall(($get_num_z, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{$itype}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Float64}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            P, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return increment!(P)
            elseif d === :q
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Q  = Vector{$itype}(undef, n_col)
                @isok ccall(($get_num_z, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{$itype}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, Q, C_NULL, C_NULL,
                            C_NULL, C_NULL, lu.numeric)
                return increment!(Q)
            elseif d === :Rs
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Rs = Vector{Float64}(undef, n_row)
                @isok ccall(($get_num_z, :libumfpack), $itype,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Float64}, Ptr{Cvoid}),
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, C_NULL, C_NULL, C_NULL,
                            C_NULL, Rs, lu.numeric)
                return Rs
            elseif d === :(:)
                umfpack_numeric!(lu)        # ensure the numeric decomposition exists
                (lnz, unz, n_row, n_col, nz_diag) = umf_lunz(lu)
                Lp = Vector{$itype}(undef, n_row + 1)
                # L is returned in CSR (compressed sparse row) format
                Lj = Vector{$itype}(undef, lnz)
                Lx = Vector{Float64}(undef, lnz)
                Lz = Vector{Float64}(undef, lnz)
                Up = Vector{$itype}(undef, n_col + 1)
                Ui = Vector{$itype}(undef, unz)
                Ux = Vector{Float64}(undef, unz)
                Uz = Vector{Float64}(undef, unz)
                P  = Vector{$itype}(undef, n_row)
                Q  = Vector{$itype}(undef, n_col)
                Rs = Vector{Float64}(undef, n_row)
                @isok ccall(($get_num_z, :libumfpack), $itype,
                            (Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Float64},
                             Ptr{$itype}, Ptr{$itype}, Ptr{Float64}, Ptr{Float64},
                             Ptr{$itype}, Ptr{$itype}, Ptr{Cvoid}, Ptr{Cvoid},
                             Ptr{Cvoid}, Ptr{Float64}, Ptr{Cvoid}),
                            Lp, Lj, Lx, Lz,
                            Up, Ui, Ux, Uz,
                            P, Q, C_NULL, C_NULL,
                            C_NULL, Rs, lu.numeric)
                return (copy(transpose(SparseMatrixCSC(min(n_row, n_col), n_row,
                                                       increment!(Lp), increment!(Lj),
                                                       complex.(Lx, Lz)))),
                        SparseMatrixCSC(min(n_row, n_col), n_col, increment!(Up),
                                        increment!(Ui), complex.(Ux, Uz)),
                        increment!(P), increment!(Q), Rs)
            else
                return getfield(lu, d)
            end
        end
    end
end

# backward compatibility
umfpack_extract(lu::UmfpackLU) = getproperty(lu, :(:))

function nnz(lu::UmfpackLU)
    lnz, unz, = umf_lunz(lu)
    return Int(lnz + unz)
end

LinearAlgebra.issuccess(lu::UmfpackLU) = lu.status == UMFPACK_OK

### Solve with Factorization

import LinearAlgebra.ldiv!

ldiv!(lu::UmfpackLU{T}, B::StridedVecOrMat{T}) where {T<:UMFVTypes} =
    ldiv!(B, lu, copy(B))
ldiv!(translu::Transpose{T,<:UmfpackLU{T}}, B::StridedVecOrMat{T}) where {T<:UMFVTypes} =
    (lu = translu.parent; ldiv!(B, transpose(lu), copy(B)))
ldiv!(adjlu::Adjoint{T,<:UmfpackLU{T}}, B::StridedVecOrMat{T}) where {T<:UMFVTypes} =
    (lu = adjlu.parent; ldiv!(B, adjoint(lu), copy(B)))
ldiv!(lu::UmfpackLU{Float64}, B::StridedVecOrMat{<:Complex}) =
    ldiv!(B, lu, copy(B))
ldiv!(translu::Transpose{Float64,<:UmfpackLU{Float64}}, B::StridedVecOrMat{<:Complex}) =
    (lu = translu.parent; ldiv!(B, transpose(lu), copy(B)))
ldiv!(adjlu::Adjoint{Float64,<:UmfpackLU{Float64}}, B::StridedVecOrMat{<:Complex}) =
    (lu = adjlu.parent; ldiv!(B, adjoint(lu), copy(B)))

ldiv!(X::StridedVecOrMat{T}, lu::UmfpackLU{T}, B::StridedVecOrMat{T}) where {T<:UMFVTypes} =
    _Aq_ldiv_B!(X, lu, B, UMFPACK_A)
ldiv!(X::StridedVecOrMat{T}, translu::Transpose{T,<:UmfpackLU{T}}, B::StridedVecOrMat{T}) where {T<:UMFVTypes} =
    (lu = translu.parent; _Aq_ldiv_B!(X, lu, B, UMFPACK_Aat))
ldiv!(X::StridedVecOrMat{T}, adjlu::Adjoint{T,<:UmfpackLU{T}}, B::StridedVecOrMat{T}) where {T<:UMFVTypes} =
    (lu = adjlu.parent; _Aq_ldiv_B!(X, lu, B, UMFPACK_At))
ldiv!(X::StridedVecOrMat{Tb}, lu::UmfpackLU{Float64}, B::StridedVecOrMat{Tb}) where {Tb<:Complex} =
    _Aq_ldiv_B!(X, lu, B, UMFPACK_A)
ldiv!(X::StridedVecOrMat{Tb}, translu::Transpose{Float64,<:UmfpackLU{Float64}}, B::StridedVecOrMat{Tb}) where {Tb<:Complex} =
    (lu = translu.parent; _Aq_ldiv_B!(X, lu, B, UMFPACK_Aat))
ldiv!(X::StridedVecOrMat{Tb}, adjlu::Adjoint{Float64,<:UmfpackLU{Float64}}, B::StridedVecOrMat{Tb}) where {Tb<:Complex} =
    (lu = adjlu.parent; _Aq_ldiv_B!(X, lu, B, UMFPACK_At))

function _Aq_ldiv_B!(X::StridedVecOrMat, lu::UmfpackLU, B::StridedVecOrMat, transposeoptype)
    if size(X, 2) != size(B, 2)
        throw(DimensionMismatch("input and output arrays must have same number of columns"))
    end
    _AqldivB_kernel!(X, lu, B, transposeoptype)
    return X
end
function _AqldivB_kernel!(x::StridedVector{T}, lu::UmfpackLU{T},
                          b::StridedVector{T}, transposeoptype) where T<:UMFVTypes
    solve!(x, lu, b, transposeoptype)
end
function _AqldivB_kernel!(X::StridedMatrix{T}, lu::UmfpackLU{T},
                          B::StridedMatrix{T}, transposeoptype) where T<:UMFVTypes
    for col in 1:size(X, 2)
        solve!(view(X, :, col), lu, view(B, :, col), transposeoptype)
    end
end
function _AqldivB_kernel!(x::StridedVector{Tb}, lu::UmfpackLU{Float64},
                          b::StridedVector{Tb}, transposeoptype) where Tb<:Complex
    r, i = similar(b, Float64), similar(b, Float64)
    solve!(r, lu, Vector{Float64}(real(b)), transposeoptype)
    solve!(i, lu, Vector{Float64}(imag(b)), transposeoptype)
    map!(complex, x, r, i)
end
function _AqldivB_kernel!(X::StridedMatrix{Tb}, lu::UmfpackLU{Float64},
                          B::StridedMatrix{Tb}, transposeoptype) where Tb<:Complex
    r = similar(B, Float64, size(B, 1))
    i = similar(B, Float64, size(B, 1))
    for j in 1:size(B, 2)
        solve!(r, lu, Vector{Float64}(real(view(B, :, j))), transposeoptype)
        solve!(i, lu, Vector{Float64}(imag(view(B, :, j))), transposeoptype)
        map!(complex, view(X, :, j), r, i)
    end
end

for Tv in (:Float64, :ComplexF64), Ti in UmfpackIndexTypes
    f = Symbol(umf_nm("free_symbolic", Tv, Ti))
    @eval begin
        function ($f)(symb::Ptr{Cvoid})
            tmp = [symb]
            ccall(($(string(f)), :libumfpack), Cvoid, (Ptr{Cvoid},), tmp)
        end

        function umfpack_free_symbolic(lu::UmfpackLU{$Tv,$Ti})
            if lu.symbolic == C_NULL return lu end
            umfpack_free_numeric(lu)
            ($f)(lu.symbolic)
            lu.symbolic = C_NULL
            return lu
        end
    end

    f = Symbol(umf_nm("free_numeric", Tv, Ti))
    @eval begin
        function ($f)(num::Ptr{Cvoid})
            tmp = [num]
            ccall(($(string(f)), :libumfpack), Cvoid, (Ptr{Cvoid},), tmp)
        end
        function umfpack_free_numeric(lu::UmfpackLU{$Tv,$Ti})
            if lu.numeric == C_NULL return lu end
            ($f)(lu.numeric)
            lu.numeric = C_NULL
            return lu
        end
    end
end

function umfpack_report_symbolic(symb::Ptr{Cvoid}, level::Real)
    old_prl::Float64 = umf_ctrl[UMFPACK_PRL]
    umf_ctrl[UMFPACK_PRL] = Float64(level)
    @isok ccall((:umfpack_dl_report_symbolic, :libumfpack), Int,
                (Ptr{Cvoid}, Ptr{Float64}), symb, umf_ctrl)
    umf_ctrl[UMFPACK_PRL] = old_prl
end

umfpack_report_symbolic(symb::Ptr{Cvoid}) = umfpack_report_symbolic(symb, 4.)

function umfpack_report_symbolic(lu::UmfpackLU, level::Real)
    umfpack_report_symbolic(umfpack_symbolic!(lu).symbolic, level)
end

umfpack_report_symbolic(lu::UmfpackLU) = umfpack_report_symbolic(lu.symbolic,4.)
function umfpack_report_numeric(num::Ptr{Cvoid}, level::Real)
    old_prl::Float64 = umf_ctrl[UMFPACK_PRL]
    umf_ctrl[UMFPACK_PRL] = Float64(level)
    @isok ccall((:umfpack_dl_report_numeric, :libumfpack), Int,
                (Ptr{Cvoid}, Ptr{Float64}), num, umf_ctrl)
    umf_ctrl[UMFPACK_PRL] = old_prl
end

umfpack_report_numeric(num::Ptr{Cvoid}) = umfpack_report_numeric(num, 4.)
function umfpack_report_numeric(lu::UmfpackLU, level::Real)
    umfpack_report_numeric(umfpack_numeric!(lu).numeric, level)
end

umfpack_report_numeric(lu::UmfpackLU) = umfpack_report_numeric(lu,4.)

end # UMFPACK module
