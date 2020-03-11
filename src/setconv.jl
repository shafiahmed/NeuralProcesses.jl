export SetConv, set_conv

"""
    SetConv{T<:AbstractVector{<:Real}}

A set convolution layer.

# Fields
- `log_scales::T`: Natural logarithm of the length scales of every input channel.
- `density:Bool`: Employ a density channel.
"""
struct SetConv{T<:AbstractVector{<:Real}}
    log_scales::T
    density::Bool
end

@Flux.treelike SetConv

"""
    set_conv(in_channels::Integer, scale::Float64; density::Bool=true)

Construct a set convolution layer.

# Arguments
- `in_channels::Integer`: Number of input channels.
- `scale::Real`: Initialisation of the length scales.

# Keywords
- `density:Bool`: Employ a density channel. This increases the number of output channels.

# Returns
- `SetConv`: Corresponding set convolution layer.
"""
function set_conv(in_channels::Integer, scale::Real; density::Bool=true)
    # Add one to `in_channels` to account for the density channel.
    density && (in_channels += 1)
    return SetConv(param(log.(scale .* ones(in_channels))), density)
end

"""
    (layer::SetConv)(
        x_context::AbstractArray{T, 3},
        y_context::AbstractArray{T, 3},
        x_target::AbstractArray{T, 3},
    ) where {T<:Real}

# Arguments
- `x_context::AbstractArray{T, 3}`: Locations of observed values of shape `(n, d, batch)`.
- `y_context::AbstractArray{T, 3}`: Observed values of shape `(n, channels, batch)`.
- `x_target::AbstractArray{T, 3}`: Discretisation locations of shape `(m, d, batch)`.
"""
function (layer::SetConv)(
    x_context::AbstractArray{T, 3},
    y_context::AbstractArray{T, 3},
    x_target::AbstractArray{T, 3},
) where {T<:Real}

    n_context = size(x_context, 1)
    dimensionality = size(x_context, 2)
    batch_size = size(x_context, 3)

    # Validate input sizes.
    @assert size(y_context, 1) == n_context
    @assert size(x_target, 2) == dimensionality
    @assert size(y_context, 3) == batch_size
    @assert size(x_target, 3) == batch_size

    # Shape: `(n, m, batch)`.
    dists2 = compute_dists2(x_context, x_target)

    # Add channel dimension.
    # Shape: `(n, m, channels, batch)`.
    dists2 = insert_dim(dists2; pos=3)

    # Apply length scales.
    # Shape: `(n, m, channels, batch)`.
    scales = reshape(exp.(layer.log_scales), 1, 1, length(layer.log_scales), 1)
    dists2 = dists2 ./ scales.^2

    # Apply RBF to compute weights.
    weights = rbf.(dists2)

    if layer.density
        # Add density channel to `y`.
        # Shape: `(n, channels + 1, batch)`.
        density = gpu(ones(eltype(y_context), n_context, 1, batch_size))
        channels = cat(density, y_context; dims=2)
    else
        channels = y_context
    end

    # Multiply with weights and sum.
    # Shape: `(m, channels + 1, batch)`.
    channels = dropdims(sum(insert_dim(channels; pos=2) .* weights; dims=1); dims=1)

    if layer.density
        # Divide by the density channel.
        density = channels[:, 1:1, :]
        others = channels[:, 2:end, :] ./ (density .+ 1e-8)
        channels = cat(density, others; dims=2)
    end

    return channels
end