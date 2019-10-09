#######################################################################
# CoverageCore.jl
# Take Julia test coverage results and bundle them up in JSONs
# https://github.com/JuliaCI/CoverageCore.jl
#######################################################################

using CoverageCore, Test, LibGit2

if VERSION < v"1.1"
isnothing(x) = false
isnothing(x::Nothing) = true
end

@testset "CoverageCore" begin
withenv("DISABLE_AMEND_COVERAGE_FROM_SRC" => nothing) do

@testset "iscovfile" begin
    # test our filename matching. These aren't exported functions but it's probably
    # a good idea to have explicit tests for them, as they're used to match files
    # that get deleted
    @test CoverageCore.iscovfile("test.jl.cov")
    @test CoverageCore.iscovfile("test.jl.2934.cov")
    @test CoverageCore.iscovfile("/home/somebody/test.jl.2934.cov")
    @test !CoverageCore.iscovfile("test.ji.2934.cov")
    @test !CoverageCore.iscovfile("test.jl.2934.cove")
    @test !CoverageCore.iscovfile("test.jicov")
    @test !CoverageCore.iscovfile("test.c.cov")
    @test CoverageCore.iscovfile("test.jl.cov", "test.jl")
    @test !CoverageCore.iscovfile("test.jl.cov", "other.jl")
    @test CoverageCore.iscovfile("test.jl.8392.cov", "test.jl")
    @test CoverageCore.iscovfile("/somedir/test.jl.8392.cov", "/somedir/test.jl")
    @test !CoverageCore.iscovfile("/otherdir/test.jl.cov", "/somedir/test.jl")
end

@testset "isfuncexpr" begin
    @test CoverageCore.isfuncexpr(:(f() = x))
    @test CoverageCore.isfuncexpr(:(function() end))
    @test CoverageCore.isfuncexpr(:(function g() end))
    @test CoverageCore.isfuncexpr(:(function g() where {T} end))
    @test !CoverageCore.isfuncexpr("2")
    @test !CoverageCore.isfuncexpr(:(f = x))
    @test CoverageCore.isfuncexpr(:(() -> x))
    @test CoverageCore.isfuncexpr(:(x -> x))
    @test CoverageCore.isfuncexpr(:(f() where A = x))
    @test CoverageCore.isfuncexpr(:(f() where A where B = x))
end

@testset "Processing coverage" begin
    cd(dirname(@__DIR__)) do
        datadir = joinpath("test", "data")
        # Process a saved set of coverage data...
        r = process_file(joinpath(datadir, "CoverageCore.jl"))

        # ... and memory data
        malloc_results = analyze_malloc(datadir)
        filename = joinpath(datadir, "testparser.jl.9172.mem")
        @test malloc_results == [CoverageCore.MallocInfo(96669, filename, 2)]

        lcov = IOBuffer()
        # we only have a single file, but we want to test on the Vector of file results
        LCOV.write(lcov, FileCoverage[r])
        expected = read(joinpath(datadir, "tracefiles", "expected.info"), String)
        if Sys.iswindows()
            expected = replace(expected, "\r\n" => "\n")
            expected = replace(expected, "SF:test/data/CoverageCore.jl\n" => "SF:test\\data\\CoverageCore.jl\n")
        end
        @test String(take!(lcov)) == expected

        # LCOV.writefile is a short-hand for writing to a file
        lcov = joinpath(datadir, "lcov_output_temp.info")
        LCOV.writefile(lcov, FileCoverage[r])
        expected = read(joinpath(datadir, "tracefiles", "expected.info"), String)
        if Sys.iswindows()
            expected = replace(expected, "\r\n" => "\n")
            expected = replace(expected, "SF:test/data/CoverageCore.jl\n" => "SF:test\\data\\CoverageCore.jl\n")
        end
        @test String(read(lcov)) == expected
        # tear down test file
        rm(lcov)

        # test that reading the LCOV file gives the same data
        lcov = LCOV.readfolder(datadir)
        @test length(lcov) == 1
        r2 = lcov[1]
        r2_filename = r2.filename
        if Sys.iswindows()
            r2_filename = replace(r2_filename, '/' => '\\')
        end
        @test r2_filename == r.filename
        @test r2.source == ""
        @test r2.coverage == r.coverage[1:length(r2.coverage)]
        @test all(isnothing, r.coverage[(length(r2.coverage) + 1):end])
        lcov2 = [FileCoverage(r2.filename, "sourcecode", CoverageCore.CovCount[nothing, 1, 0, nothing, 3]),
                 FileCoverage("file2.jl", "moresource2", CoverageCore.CovCount[1, nothing, 0, nothing, 2]),]
        lcov = merge_coverage_counts(lcov, lcov2, lcov)
        @test length(lcov) == 2
        r3 = lcov[1]
        @test r3.filename == r2.filename
        @test r3.source == "sourcecode"
        r3cov = CoverageCore.CovCount[x === nothing ? nothing : x * 2 for x in r2.coverage]
        r3cov[2] += 1
        r3cov[3] = 0
        r3cov[5] = 3
        @test r3.coverage == r3cov
        r4 = lcov[2]
        @test r4.filename == "file2.jl"
        @test r4.source == "moresource2"
        @test r4.coverage == lcov2[2].coverage

        # Test a file from scratch
        srcname = joinpath("test", "data", "testparser.jl")
        covname = srcname*".cov"
        # clean out any previous coverage files. Don't use clean_folder because we
        # need to preserve the pre-baked coverage file CoverageCore.jl.cov
        clean_file(srcname)
        cmdstr = "include($(repr(srcname))); using Test; @test f2(2) == 4"
        run(`$(Base.julia_cmd()) --startup-file=no --code-coverage=user -e $cmdstr`)
        r = process_file(srcname, datadir)

        target = CoverageCore.CovCount[nothing, 2, nothing, 0, nothing, 0, nothing, nothing, nothing, nothing, 0, nothing, nothing, nothing, nothing, nothing, 0, nothing, nothing, 0, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing]
        target_disabled = map(x -> (x !== nothing && x > 0) ? x : nothing, target)
        @test r.coverage == target

        covtarget = (sum(x->x !== nothing && x > 0, target), sum(x->x !== nothing, target))
        @test get_summary(r) == covtarget
        @test get_summary(process_folder(datadir)) == (98, 106)

        r_disabled = withenv("DISABLE_AMEND_COVERAGE_FROM_SRC" => "yes") do
            process_file(srcname, datadir)
        end

        @test r_disabled.coverage == target_disabled
        amend_coverage_from_src!(r_disabled.coverage, r_disabled.filename)
        @test r_disabled.coverage == target

        # Handle an empty coverage vector
        emptycov = FileCoverage("", "", [])
        @test get_summary(emptycov) == (0, 0)

        @test isempty(CoverageCore.process_cov(joinpath("test", "fakefile"), datadir))

        # test clean_folder
        # set up the test folder
        datadir_temp = joinpath("test", "data_temp")
        cp(datadir, datadir_temp)
        # run clean_folder
        clean_folder(datadir_temp)
        # .cov files should be deleted
        @test !isfile(joinpath(datadir_temp, "CoverageCore.jl.cov"))
        # other files should remain untouched
        @test isfile(joinpath(datadir_temp, "CoverageCore.jl"))
        # tear down test data
        rm(datadir_temp; recursive=true)
    end
end

end # of withenv("DISABLE_AMEND_COVERAGE_FROM_SRC" => nothing)

end # of @testset "CoverageCore"
