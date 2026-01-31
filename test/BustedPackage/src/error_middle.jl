# Test file with error in middle
function works()
    return 1
end

function broken()
    for x [1,2,3]
        println(x)
    end
end

function also_works()
    return 2
end
