import CoverageTools
coveragetools_cov_res = CoverageTools.process_folder()

import Pkg
Pkg.add("Coverage")
import Coverage
coverage_cov_res = Coverage.process_folder()

retry(() -> Coverage.Coveralls.submit(coverage_cov_res); delays = ExponentialBackOff(n = 5))()
retry(() -> Coverage.Codecov.submit(coverage_cov_res); delays = ExponentialBackOff(n = 5))()
