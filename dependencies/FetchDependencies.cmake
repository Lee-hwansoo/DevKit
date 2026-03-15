# =============================================================================
# C++ Dependencies (CMake FetchContent)
# =============================================================================
# 이 파일을 프로젝트의 메인 CMakeLists.txt 에서 include 하여 사용하세요.
# 예: include(dependencies/FetchDependencies.cmake)

include(FetchContent)

# <예시: nlohmann/json 라이브러리 가져오기>
# FetchContent_Declare(
#     json
#     GIT_REPOSITORY https://github.com/nlohmann/json.git
#     GIT_TAG v3.11.2
# )
# FetchContent_MakeAvailable(json)
