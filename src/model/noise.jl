export Deterministic, FixedGaussian, AmortisedGaussian, HeterogeneousGaussian, build_noise_model

"""
    abstract type Noise
"""
abstract type Noise end

"""
    struct Deterministic <: Noise
"""
struct Deterministic <: Noise end

@Flux.functor Deterministic

(noise::Deterministic)(x::AA) = Dirac(x)

"""
    struct FixedGaussian <: Noise

Gaussian noise with a fixed standard deviation.

# Fields
- `log_σ`: Natural logarithm of the fixed standard deviation.
"""
struct FixedGaussian <: Noise
    log_σ
end

@Flux.functor FixedGaussian

(noise::FixedGaussian)(x::AA) = Normal(x, exp.(unwrap(noise.log_σ)))

"""
    struct AmortisedGaussian <: Noise

Gaussian noise with an amortised fixed standard deviation.

# Fields
- `offset`: Amount to subtract from the transformed standard deviation to help
    initialisation.
"""
struct AmortisedGaussian <: Noise
    offset
end

AmortisedGaussian() = AmortisedGaussian(2)

@Flux.functor AmortisedGaussian

(noise::AmortisedGaussian)(x::Parallel{2}) = Normal(x[1], softplus(x[2] .- noise.offset))

"""
    struct HeterogeneousGaussian <: Noise

# Fields
- `offset`: Amount to subtract from the transformed standard deviation to help
    initialisation.
"""
struct HeterogeneousGaussian <: Noise
    offset
end

HeterogeneousGaussian() = HeterogeneousGaussian(2)

@Flux.functor HeterogeneousGaussian

function (noise::HeterogeneousGaussian)(x::AA)
    μ, σ_transformed = split(x, 2)
    return Normal(μ, softplus(σ_transformed .- noise.offset))
end

"""
    struct CorrelatedGaussian <: Noise
"""
struct CorrelatedGaussian <: Noise
    log_σ
end

CorrelatedGaussian() = CorrelatedGaussian([log(1f-1)])

@Flux.functor CorrelatedGaussian

function (noise::CorrelatedGaussian)(x::Parallel{2})
    μ = x[1]
    Σ = x[2]
    n = size(Σ, 1)
    eye = gpu(Matrix(I, n, n))
    return CorrelatedNormal(μ, Σ .+ exp.(noise.log_σ) .* eye)
end

"""
    build_noise_model(
        build_local_transform=n -> identity;
        dim_y::Integer=1,
        noise_type::String="het",
        pooling_type::String="mean",
        σ::Float32=1f-2,
        learn_σ::Bool=true,
        num_amortised_σ_channels::Integer=8
    )

# Arguments
- `build_local_transform`: Transform to apply to any local quantities (mean and
    heterogeneous standard deviation) before calculating the noise.
- `dim_y::Integer=1`: Dimensionality of the outputs.
- `noise_type::String="het"`: Type of noise model. Must be "fixed", "amortised", or "het".
- `pooling_type::String="mean"`: Type of pooling. Must be "mean" or "sum".
- `σ::Float32=1f-2`: Initialisation of the fixed observation noise.
- `learn_σ::Bool=true`: Learn the fixed observation noise.
- `num_amortised_σ_channels::Integer`: Number of channels to allocate for the
    amortised noise, if it is used.

# Returns
- `Tuple`: Tuple containing the number of channels required for the noise model and the
    noise model.
"""
function build_noise_model(
    build_local_transform=n -> identity;
    dim_y::Integer=1,
    noise_type::String="het",
    pooling_type::String="mean",
    σ::Float32=1f-2,
    learn_σ::Bool=true,
    num_amortised_σ_channels::Integer=8
)
    # Fixed observation noise:
    if noise_type == "fixed"
        num_noise_channels = dim_y
        noise = Chain(
            build_local_transform(dim_y),
            FixedGaussian(learn_σ ? [log(σ)] : Fixed([log(σ)]))
        )

    # Amortised observation noise:
    elseif noise_type == "amortised"
        if pooling_type == "mean"
            pooling = MeanPooling(layer_norm(1, num_amortised_σ_channels, 1))
        elseif pooling_type == "sum"
            pooling = SumPooling(1000)  # Divide by `1000` to help initialisation.
        else
            error("Unknown pooling type \"" * pooling_type * "\".")
        end
        num_noise_channels = dim_y + num_amortised_σ_channels
        noise = Chain(
            Splitter(num_amortised_σ_channels),
            Parallel(
                build_local_transform(dim_y),
                Chain(
                    batched_mlp(
                        dim_in    =num_amortised_σ_channels,
                        dim_hidden=num_amortised_σ_channels,
                        dim_out   =num_amortised_σ_channels,
                        num_layers=3
                    ),
                    pooling,
                    batched_mlp(
                        dim_in    =num_amortised_σ_channels,
                        dim_hidden=num_amortised_σ_channels,
                        dim_out   =1,
                        num_layers=3
                    )
                )
            ),
            AmortisedGaussian(2)  # Use an offset of `2` to help initialisation.
        )

    # Heterogeneous observation noise:
    elseif noise_type == "het"
        num_noise_channels = 2dim_y
        noise = Chain(
            build_local_transform(2dim_y),
            HeterogeneousGaussian(2)  # Use an offset of `2` to help initialisation.
        )

    else
        error("Unknown noise type \"" * noise_type * "\".")
    end

    return num_noise_channels, noise
end
