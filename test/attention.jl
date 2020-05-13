@testset "attention.jl" begin
    @testset "Attention" begin
        dim_x = 2
        dim_y = 3
        dim_embedding = 20
        num_heads = 5
        batch_size = 6
        n = 7
        m = 8

        layer = ConvCNPs.untrack(attention(
            dim_x=dim_x,
            dim_y=dim_y,
            dim_embedding=dim_embedding,
            num_heads=num_heads
        ))

        xc = randn(Float32, n, dim_x, batch_size)
        yc = randn(Float32, n, dim_y, batch_size)
        xt = randn(Float32, m, dim_x, batch_size)

        # Perform encodings.
        keys = layer.encoder_x(xc)
        queries = layer.encoder_x(xt)
        values = layer.encoder_xy(cat(xc, yc, dims=2))

        dim_head = div(dim_embedding, num_heads)

        # Brute-force the attention computation.
        embeddings = zeros(Float32, m, dim_head, num_heads, batch_size)
        for c = 1:num_heads
            for b = 1:batch_size
                # Calculate weights.
                weights = Array{Float32}(undef, n, m)
                for i = 1:n, j = 1:m
                    weights[i, j] = exp(dot(keys[i, :, c, b], queries[j, :, c, b]))
                end
                for j = 1:m
                    weights[:, j] ./= sum(weights[:, j])
                end

                # Normalise by size of the embedding.
                weights ./= Float32(sqrt(dim_embedding))

                # Calculate embeddings.
                for i = 1:n, j = 1:m
                    embeddings[j, :, c, b] .+= values[i, :, c, b] .* weights[i, j]
                end
            end
        end

        reference = layer.transformer(layer.mixer(embeddings), queries)

        # Check that the layer lines up with the brute-force reference.
        @test layer(xc, yc, xt) ≈ reference
    end

    @testset "BatchedMLP" begin
        layer = ConvCNPs.untrack(ConvCNPs.batched_mlp(
            dim_in=2,
            dim_out=3,
            dim_hidden=10,
            num_layers=3
        ))
        x = randn(10, 2, 4, 5)
        @test size(layer(x)) == (10, 3, 4, 5)
    end
end
