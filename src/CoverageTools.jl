module CoverageTools

import JuliaSyntax
import TOML

export process_folder, process_file
export clean_folder, clean_file
export process_cov, amend_coverage_from_src!
export get_summary
export analyze_malloc, merge_coverage_counts
export FileCoverage

# The unit for line counts. Counts can be >= 0 or nothing, where
# the nothing means it doesn't make sense to have a count for this
# line (e.g. a comment), but 0 means it could have run but didn't.
const CovCount = Union{Nothing,Int}

"""
    has_embedded_errors(expr)

Recursively check if an expression contains any `:error` nodes.
"""
function has_embedded_errors(expr)
    if expr isa Expr
        if expr.head === :error
            return true
        end
        for arg in expr.args
            if has_embedded_errors(arg)
                return true
            end
        end
    end
    return false
end

"""
    find_error_line(expr)

Find the line number of the first error in an expression by locating
the LineNumberNode or Expr(:line) that precedes the first :error node.
Returns nothing if no error is found.
"""
function find_error_line(expr, last_line=nothing)
    if expr isa LineNumberNode
        return expr.line, false
    end

    if expr isa Expr
        # Handle Expr(:line, ...) nodes emitted by JuliaSyntax
        if expr.head === :line && length(expr.args) >= 1
            line_num = expr.args[1]
            if line_num isa Integer
                return Int(line_num), false
            end
        end
        
        if expr.head === :error
            # Found an error, return the last seen line number
            return last_line, true
        end

        current_line = last_line
        for arg in expr.args
            line_result, found_error = find_error_line(arg, current_line)
            if found_error
                return line_result, true
            end
            if line_result !== nothing && !found_error
                current_line = line_result
            end
        end
    end

    return nothing, false
end

"""
FileCoverage

Represents coverage info about a file, including the filename, the source
code itself, and a `Vector` of run counts for each line. If the
line was expected to be run the count will be an `Int` >= 0. Other lines
such as comments will have a count of `nothing`.
"""
mutable struct FileCoverage
    filename::AbstractString
    source::AbstractString
    coverage::Vector{CovCount}
end

"""
    get_summary(fcs)

Summarize results from a single `FileCoverage` instance or a `Vector` of
them, returning a 2-tuple with the covered lines and total lines.
"""
function get_summary end

function get_summary(fc::FileCoverage)
    if !isempty(fc.coverage)
        cov_lines = sum(x -> x !== nothing && x > 0, fc.coverage)
        tot_lines = sum(x -> x !== nothing, fc.coverage)
    else
        cov_lines = 0
        tot_lines = 0
    end
    return cov_lines, tot_lines
end

function get_summary(fcs::Vector{FileCoverage})
    cov_lines, tot_lines = 0, 0
    for fc in fcs
        c, t = get_summary(fc)
        cov_lines += c
        tot_lines += t
    end
    return cov_lines, tot_lines
end

"""
    merge_coverage_counts(a1::Vector{CovCount}, a2::Vector{CovCount}) -> Vector{CovCount}

Given two vectors of line coverage counts, sum together the results,
preseving null counts if both are null.
"""
function merge_coverage_counts(a1::Vector{CovCount},
                               a2::Vector{CovCount})
    n = max(length(a1), length(a2))
    a = Vector{CovCount}(undef, n)
    for i in 1:n
        a1v = isassigned(a1, i) ? a1[i] : nothing
        a2v = isassigned(a2, i) ? a2[i] : nothing
        a[i] = a1v === nothing ? a2v :
               a2v === nothing ? a1v :
               a1v + a2v
    end
    return a
end

"""
    merge_coverage_counts(as::Vector{CovCount}...) -> Vector{CovCount}

Given vectors of line coverage counts, sum together the results,
preseving null counts if both are null.
"""
function merge_coverage_counts(as::Vector{FileCoverage}...)
    source_files = FileCoverage[]
    seen = Dict{AbstractString, FileCoverage}()
    for a in as
        for a in a
            if a.filename in keys(seen)
                coverage = seen[a.filename]
                if isempty(coverage.source)
                    coverage.source = a.source
                end
                coverage.coverage = merge_coverage_counts(coverage.coverage, a.coverage)
            else
                coverage = FileCoverage(a.filename, a.source, a.coverage)
                seen[a.filename] = coverage
                push!(source_files, coverage)
            end
        end
    end
    return source_files
end

"""
    process_cov(filename, folder) -> Vector{CovCount}

Given a filename for a Julia source file, produce an array of
line coverage counts by reading in all matching .{pid}.cov files.
"""
function process_cov(filename, folder)
    # Find all coverage files in the folder that match the file we
    # are currently working on
    files = readdir(folder)
    files = map!(file -> joinpath(folder, file), files, files)
    filter!(file -> occursin(filename, file) && occursin(".cov", file), files)
    # If there are no coverage files...
    if isempty(files)
        # ... we will assume that, as there is a .jl file, it was
        # just never run. We'll report the coverage as all null.
        @info """CoverageTools.process_cov: Coverage file(s) for $filename do not exist.
                                          Assuming file has no coverage."""
        nlines = countlines(filename)
        return fill!(Vector{CovCount}(undef, nlines), nothing)
    end
    # Keep track of the combined coverage
    full_coverage = CovCount[]
    for file in files
        @info "CoverageTools.process_cov: processing $file"
        coverage = CovCount[]
        for line in eachline(file)
            # Columns 1:9 contain the coverage count
            cov_segment = line[1:9]
            # If coverage is NA, there will be a dash
            push!(coverage, cov_segment[9] == '-' ? nothing : parse(Int, cov_segment))
        end
        full_coverage = merge_coverage_counts(full_coverage, coverage)
    end
    return full_coverage
end

"""
    detect_syntax_version(filename::AbstractString) -> VersionNumber

Detect the appropriate Julia syntax version for parsing a source file by looking
for the nearest project file (Project.toml or JuliaProject.toml) and reading its
syntax version configuration, or by looking for the VERSION file in Julia's own
source tree (for base/ files).

Defaults to v"1.14" if no specific version is found, as JuliaSyntax generally
maintains backwards compatibility with older syntax.
"""
function detect_syntax_version(filename::AbstractString)
    dir = dirname(abspath(filename))
    # Walk up the directory tree looking for project file or VERSION file
    while true
        # Check for project file first (for packages and stdlib)
        # Use Base.locate_project_file to handle both Project.toml and JuliaProject.toml
        project_file = Base.locate_project_file(dir)

        if project_file !== nothing && project_file !== true && isfile(project_file)
            # Use Base.project_file_load_spec if available (Julia 1.14+)
            # This properly handles syntax.julia_version entries
            if isdefined(Base, :project_file_load_spec)
                spec = Base.project_file_load_spec(project_file, "")
                return spec.julia_syntax_version
            else
                # Fallback for older Julia versions - only check syntax.julia_version
                project = TOML.tryparsefile(project_file)
                if !(project isa Base.TOML.ParserError)
                    syntax_table = get(project, "syntax", nothing)
                    if syntax_table !== nothing
                        jv = get(syntax_table, "julia_version", nothing)
                        if jv !== nothing
                            try
                                return VersionNumber(jv)
                            catch e
                                e isa ArgumentError || rethrow()
                            end
                        end
                    end
                end
            end
        end

        # Check for VERSION file (for Julia's own base/ source without project file)
        version_file = joinpath(dir, "VERSION")
        if isfile(version_file)
            version_str = nothing
            try
                version_str = strip(read(version_file, String))
            catch e
                e isa SystemError || rethrow()
                # If we can't read VERSION, continue searching
            end
            if version_str !== nothing
                # Parse version string like "1.14.0-DEV"
                m = match(r"^(\d+)\.(\d+)", version_str)
                if m !== nothing
                    try
                        major = parse(Int, m.captures[1])
                        minor = parse(Int, m.captures[2])
                        return VersionNumber(major, minor)
                    catch e
                        e isa ArgumentError || rethrow()
                        # If we can't parse VERSION, continue searching
                    end
                end
            end
        end

        parent = dirname(dir)
        if parent == dir  # reached root
            break
        end
        dir = parent
    end
    # Default to v"1.14" - JuliaSyntax maintains backwards compatibility
    # so using a recent version generally works for older code
    return v"1.14"
end

"""
    amend_coverage_from_src!(coverage::Vector{CovCount}, srcname)
    amend_coverage_from_src!(fc::FileCoverage)

The code coverage functionality in Julia only reports lines that have been
compiled. Unused functions (or discarded lines) therefore may be incorrectly
recorded as `nothing` but should instead be 0.
This function takes an existing result and updates the coverage vector
in-place to mark source lines that may be inside a function.
"""
amend_coverage_from_src!(coverage::Vector{CovCount}, srcname) = amend_coverage_from_src!(FileCoverage(srcname, read(srcname, String), coverage))
function amend_coverage_from_src!(fc::FileCoverage)
    # The code coverage results produced by Julia itself report some
    # lines as "null" (cannot be run), when they could have been run
    # but were never compiled (thus should be 0).
    # We use the Julia parser to augment the coverage results by identifying this code.
    #
    # To make sure things stay in sync, parse the file position
    # corresponding to each new line
    content, coverage = fc.source, fc.coverage
    linepos = Int[]
    let io = IOBuffer(content)
        while !eof(io)
            push!(linepos, position(io))
            readline(io)
        end
        push!(linepos, position(io))
    end
    pos = 1
    # Detect the appropriate syntax version for this package
    syntax_version = detect_syntax_version(fc.filename)
    # When parsing, use the detected syntax version to ensure we can parse
    # all syntax features available in that version, even when running under
    # a different Julia version (e.g., parsing Julia 1.14 code with Julia 1.11).
    # JuliaSyntax provides version-aware parsing for any Julia version.
    while pos <= length(content)
        # We now want to convert the one-based offset pos into a line
        # number, by looking it up in linepos. But linepos[i] contains the
        # zero-based offset of the start of line i; since pos is
        # one-based, we have to subtract 1 before searching through
        # linepos. The result is a one-based line number; since we use
        # that later on to shift other one-based line numbers, we must
        # subtract 1 from the offset to make it zero-based.
        lineoffset = searchsortedlast(linepos, pos - 1) - 1
        # Compute actual 1-based line number for error reporting
        current_line = searchsortedlast(linepos, pos - 1)

        # now we can parse the next chunk of the input
        local ast, newpos
        try
            ast, newpos = JuliaSyntax.parsestmt(Expr, content, pos;
                                                version=syntax_version,
                                                ignore_errors=true,
                                                ignore_warnings=true)
        catch e
            if isa(e, JuliaSyntax.ParseError)
                throw(Base.Meta.ParseError("parsing error in $(fc.filename):$current_line: $e", e))
            end
            rethrow()
        end

        # If position didn't advance, we have a malformed token/byte - throw error
        if newpos <= pos
            throw(Base.Meta.ParseError("parsing error in $(fc.filename):$current_line: parser did not advance", nothing))
        end
        pos = newpos

        isa(ast, Expr) || continue
        # For files with only actual parse errors (not end-of-file), we should throw
        # But we need to distinguish real errors from benign cases
        if ast.head === :error
            errmsg = isempty(ast.args) ? "" : string(ast.args[1])
            # Only treat as EOF if we're actually at end of content AND it's an empty error or premature EOF
            if pos >= length(content) && (isempty(errmsg) || occursin("premature end of input", errmsg))
                break  # Done parsing, no more content
            end
            # Real parse error - throw it
            throw(Base.Meta.ParseError("parsing error in $(fc.filename):$current_line: $errmsg", nothing))
        end
        # Check if the AST contains any embedded :error nodes (from ignore_errors=true)
        if has_embedded_errors(ast)
            # Try to find the actual line where the error occurred
            error_internal_line, found = find_error_line(ast)
            if found && error_internal_line !== nothing
                # error_internal_line is relative to the parsed content (1-based)
                # We need to add lineoffset to get the actual file line
                error_line = lineoffset + error_internal_line
                throw(Base.Meta.ParseError("parsing error in $(fc.filename):$error_line", nothing))
            else
                # Fallback to the line where we started parsing this statement
                throw(Base.Meta.ParseError("parsing error in $(fc.filename):$current_line", nothing))
            end
        end
        # Incomplete expressions indicate truncated/malformed code - treat as parse error
        if ast.head === :incomplete
            throw(Base.Meta.ParseError("parsing error in $(fc.filename):$current_line: incomplete expression", nothing))
        end
        flines = function_body_lines(ast, coverage, lineoffset)
        if !isempty(flines)
            flines .+= lineoffset
            for l in flines
                (l > length(coverage)) && resize!(coverage, l)
                if coverage[l] === nothing
                    coverage[l] = 0
                end
            end
        end
    end

    # check for excluded lines
    let io = IOBuffer(content)
        excluded = false
        for (l, line) in enumerate(eachline(io))
            # check for start/stop markers
            if occursin("COV_EXCL_START", line)
                excluded = true
            elseif occursin("COV_EXCL_STOP", line)
                excluded = false
            end

            # also check for line markers
            if excluded || occursin("COV_EXCL_LINE", line)
                coverage[l] = nothing
            end
        end
    end

    nothing
end

"""
    process_file(filename[, folder]) -> FileCoverage

Given a .jl file and its containing folder, produce a corresponding
`FileCoverage` instance from the source and matching coverage files. If the
folder is not given it is extracted from the filename.
"""
function process_file end

function process_file(filename, folder)
    @info "CoverageTools.process_file: Detecting coverage for $filename"
    coverage = process_cov(filename, folder)
    fc = FileCoverage(filename, read(filename, String), coverage)
    if get(ENV, "DISABLE_AMEND_COVERAGE_FROM_SRC", "no") != "yes"
        amend_coverage_from_src!(fc)
    end
    return fc
end
process_file(filename) = process_file(filename, splitdir(filename)[1])

"""
    process_folder(folder="src") -> Vector{FileCoverage}

Process the contents of a folder of Julia source code to collect coverage
statistics for all the files contained within. Will recursively traverse
child folders. Default folder is "src", which is useful for the primary case
where CoverageTools is called from the root directory of a package.
"""
function process_folder(folder="src")
    @info "CoverageTools.process_folder: Searching $folder for .jl files..."
    source_files = FileCoverage[]
    files = readdir(folder)
    for file in files
        fullfile = joinpath(folder, file)
        if isfile(fullfile)
            # Is it a Julia file?
            if splitext(fullfile)[2] == ".jl"
                push!(source_files, process_file(fullfile, folder))
            else
                @debug "CoverageTools.process_folder: Skipping $file, not a .jl file"
            end
        elseif isdir(fullfile)
            # If it is a folder, recursively traverse
            append!(source_files, process_folder(fullfile))
        end
    end
    return source_files
end

# matches julia allocation files with and without the PID
ismemfile(filename) = occursin(r"\.jl\.?[0-9]*\.mem$", filename)
# matches an allocation file for the given sourcefile. They can be full paths
# with directories, but the directories must match
function ismemfile(filename, sourcefile)
    startswith(filename, sourcefile) || return false
    ismemfile(filename)
end

# matches julia coverage files with and without the PID
iscovfile(filename) = occursin(r"\.jl\.?[0-9]*\.cov$", filename)
# matches a coverage file for the given sourcefile. They can be full paths
# with directories, but the directories must match
function iscovfile(filename, sourcefile)
    startswith(filename, sourcefile) || return false
    iscovfile(filename)
end

"""
    clean_folder(folder::AbstractString; include_memfiles::Bool=false)

Cleans up all the `.cov` and optionally `.mem` files in the given directory and subdirectories.
Unlike `process_folder` this does not include a default value
for the root folder, requiring the calling code to be more explicit about
which files will be deleted.
"""
function clean_folder(folder::AbstractString; include_memfiles::Bool=false)
    files = readdir(folder)
    for file in files
        fullfile = joinpath(folder, file)
        if isfile(fullfile) && ( iscovfile(file) || (include_memfiles && ismemfile(file)) )
            # we have ourselves a coverage/memory file. eliminate it
            @info "Removing $fullfile"
            rm(fullfile)
        elseif isdir(fullfile)
            clean_folder(fullfile; include_memfiles=include_memfiles)
        end
    end
    nothing
end

"""
    clean_file(filename::AbstractString; include_memfiles::Bool=false)

Cleans up all `.cov` and optionally `.mem` files associated with a given source file. This only
looks in the directory of the given file, i.e. the `.cov`/`.mem` files should be
siblings of the source file.
"""
function clean_file(filename::AbstractString; include_memfiles::Bool=false)
    folder = splitdir(filename)[1]
    files = readdir(folder)
    for file in files
        fullfile = joinpath(folder, file)
        if isfile(fullfile) && ( iscovfile(fullfile, filename) || (include_memfiles && ismemfile(fullfile, filename)) )
            @info("Removing $(fullfile)")
            rm(fullfile)
        end
    end
end

include("lcov.jl")
include("memalloc.jl")
include("parser.jl")

end # module
