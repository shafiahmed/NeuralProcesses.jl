export Model, loglik, elbo, predict

"""
    struct Model

# Fields
- `encoder::Aggregator`: Encoder.
- `decoder`: Decoder.
"""
struct Model
    encoder::Aggregator
    decoder
end

@Flux.treelike Model

function (model::Model)(xc::AA, yc::AA, xt::AA; num_samples::Integer=1, kws...)
    xz, pz = encode(model.encoder, xc, yc, xt; kws...)
    z = sample(pz, num_samples=num_samples)
    _, d = decode(model.decoder, xz, z, xt)
    return d
end

"""
    loglik(
        model::Model,
        epoch::Integer,
        xc::AA,
        yc::AA,
        xt::AA,
        yt::AA;
        num_samples::Integer,
        batch_size::Integer=1024,
        importance_weighted::Bool=true,
        fixed_σ::Float32=1f-2,
        fixed_σ_epochs::Integer=0,
        kws...
    )

Log-expected-likelihood loss. This is a biased estimate of the log-likelihood.

# Arguments
- `model::AbstractNP`: Model.
- `epoch::Integer`: Current epoch.
- `xc::AA`: Locations of context set of shape `(n, dims, batch)`.
- `yc::AA`: Observed values of context set of shape `(n, channels, batch)`.
- `xt::AA`: Locations of target set of shape `(m, dims, batch)`.
- `yt::AA`: Observed values of target set of shape `(m, channels, batch)`.

# Keywords
- `num_samples::Integer`: Number of samples.
- `batch_size::Integer=1024`: Batch size to use in sampling.
- `importance_weighted::Bool=true`: Do an importance-weighted estimate.
- `fixed_σ::Float32=1f-2`: Hold the observation noise fixed to this value initially.
- `fixed_σ_epochs::Integer=0`: Number of iterations to hold the observation noise fixed for.
- `kws...`: Further keywords to pass on.

# Returns
- `Real`: Average negative log-expected likelihood.

"""
function loglik(
    model::Model,
    epoch::Integer,
    xc::AA,
    yc::AA,
    xt::AA,
    yt::AA;
    num_samples::Integer,
    batch_size::Integer=1024,
    importance_weighted::Bool=true,
    fixed_σ::Float32=1f-2,
    fixed_σ_epochs::Integer=0,
    kws...
)
    # Determine batches.
    num_batches, batch_size_last = divrem(num_samples, batch_size)
    batches = Int[batch_size for _ = 1:num_batches]
    batch_size_last > 0 && push!(batches, batch_size_last)

    # Initialise variable that accumulates the log-pdfs.
    logpdfs = nothing

    # Perform encoding.
    xz, pz = encode(model.encoder, xc, yc, xt; kws...)

    if importance_weighted
        # Construct posterior over latent variable for an importance-weighted estimate.
        x_all = cat(xc, xt, dims=1)
        y_all = cat(yc, yt, dims=1)
        xz, qz = reencode_stochastic(model.encoder, pz, x_all, y_all, x_all, xz; kws...)
    end

    # Compute the loss in a batched way.
    for batch in batches
        if importance_weighted
            # Sample from posterior.
            z = sample(qz, num_samples=batch)

            # Do an importance weighted estimate.
            weights = sum(logpdf(pz, z), dims=(1, 2)) .- sum(logpdf(qz, z), dims=(1, 2))
        else
            # Sample from the prior.
            z = sample(pz, num_samples=batch)

            # Do a regular Monte Carlo estimate.
            weights = 0
        end

        # Perform decoding
        _, d = decode(model.decoder, xz, z, xt)

        # Fix the noise for the early epochs to force the model to fit.
        if epoch <= fixed_σ_epochs
            d = Normal(mean(d), [fixed_σ] |> gpu)
        end

        # Perform Monte Carlo estimate.
        batch_logpdfs = weights .+ sum(logpdf(d, yt), dims=(1, 2))

        # Accumulate sum.
        logpdfs = isnothing(logpdfs) ? batch_logpdfs : cat(logpdfs, batch_logpdfs, dims=4)
        logpdfs = logsumexp(logpdfs, dims=4)
    end

    # Turn log-sum-exp into a log-mean-exp.
    logpdfs = logpdfs .- Float32(log(num_samples))

    # Return average over batches.
    return -mean(logpdfs)
end

"""
    elbo(
        model::Model,
        epoch::Integer,
        xc::AA,
        yc::AA,
        xt::AA,
        yt::AA;
        num_samples::Integer,
        fixed_σ::Float32=1f-2,
        fixed_σ_epochs::Integer=0,
        kws...
    )

Neural process ELBO-style loss. Subsumes the context set into the target set.

# Arguments
- `model::AbstractNP`: Model.
- `epoch::Integer`: Current epoch.
- `xc::AA`: Locations of context set of shape `(n, dims, batch)`.
- `yc::AA`: Observed values of context set of shape `(n, channels, batch)`.
- `xt::AA`: Locations of target set of shape `(m, dims, batch)`.
- `yt::AA`: Observed values of target set of shape `(m, channels, batch)`.

# Keywords
- `num_samples::Integer`: Number of samples.
- `fixed_σ::Float32=1f-2`: Hold the observation noise fixed to this value initially.
- `fixed_σ_epochs::Integer=0`: Number of iterations to hold the observation noise fixed for.
- `kws...`: Further keywords to pass on.

# Returns
- `Real`: Average negative NP loss.
"""
function elbo(
    model::Model,
    epoch::Integer,
    xc::AA,
    yc::AA,
    xt::AA,
    yt::AA;
    num_samples::Integer,
    fixed_σ::Float32=1f-2,
    fixed_σ_epochs::Integer=0,
    kws...
)
    # We subsume the context set into the target set for this ELBO.
    x_all = cat(xc, xt, dims=1)
    y_all = cat(yc, yt, dims=1)

    # Perform deterministic and latent encoding.
    xz, pz = encode(model.encoder, xc, yc, x_all; kws...)

    # Construct posterior over latent variable.
    _, qz = reencode_stochastic(model.encoder, pz, x_all, y_all, x_all, xz; kws...)

    # Sample latent variable and perform decoding.
    z = sample(qz, num_samples=num_samples)
    _, d = decode(model.decoder, xz, z, x_all)

    # Fix the noise for the early epochs to force the model to fit.
    if epoch <= fixed_σ_epochs
        d = Normal(mean(d), [fixed_σ] |> gpu)
    end

    # Estimate ELBO from samples.
    elbos = mean(sum(logpdf(d, y_all), dims=(1, 2)), dims=4) .- sum(kl(qz, pz), dims=(1, 2))

    # Return average over batches.
    return -mean(elbos)
end

"""
    predict(model::AbstractNP, xc::AV, yc::AV, xt::AV; num_samples::Integer=10)

# Arguments
- `model::AbstractNP`: Model.
- `xc::AV`: Locations of observed values of shape `(n)`.
- `yc::AV`: Observed values of shape `(n)`.
- `xt::AV`: Locations of target values of shape `(m)`.

# Keywords
- `num_samples::Integer=10`: Number of posterior samples.
- `kw...`: Further keywords to pass on.

# Returns
- `Tuple`:  Tuple containing means, lower and upper 95% central credible bounds, and
    `num_samples` posterior samples.
"""
function predict(model::Model, xc::AV, yc::AV, xt::AV; num_samples::Integer=10, kws...)
    # Run model.
    d = untrack(model)(
        expand_gpu.((xc, yc, xt))...;
        num_samples=max(num_samples, 100),
        kws...
    )
    μ = mean(d)[:, 1, 1, :] |> cpu
    σ = std(d)[:, 1, 1, :] |> cpu

    if size(μ, 2) >= num_samples
        samples = μ[:, 1:num_samples]
    else
        # There are no samples.
        samples = nothing
    end

    # Estimate uncertainty by adding the errors. Gaussianise to make it appear smoother.
    μ_σ = std(μ, dims=2)                            # Compute functional uncertainty.
    ε = 2 .* mean(sqrt.(μ_σ.^2 .+ σ.^2), dims=2)    # Add variances to make total error.

    # Compute bounds.
    μ = mean(μ, dims=2)
    lowers = μ .- ε
    uppers = μ .+ ε

    return μ, lowers, uppers, samples
end