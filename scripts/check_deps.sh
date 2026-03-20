#!/bin/bash
# scripts/check_deps.sh
# 빌드 아티팩트의 런타임 공유 라이브러리 의존성 누락 여부 검사

TARGET_DIR=${1:-/workspace/install}
MISSING_COUNT=0

echo "[Sanity Check] Scanning for missing dependencies in $TARGET_DIR..."

# 실행 파일 및 공유 라이브러리(.so) 찾기
find "$TARGET_DIR" -type f \( -executable -o -name "*.so*" \) ! -name "*.py" -print0 | while IFS= read -r -d '' file; do
    # ELF 파일인지 확인 (바이너리 파일만 ldd 실행)
    if file "$file" | grep -qE 'ELF|shared object'; then
        MISSING=$(ldd "$file" 2>/dev/null | grep "not found")
        if [ -n "$MISSING" ]; then
            echo -e "\033[0;31m[ERROR]\033[0m Missing dependencies for: $file"
            echo "$MISSING" | sed 's/^/  /'
            MISSING_COUNT=$((MISSING_COUNT + 1))
        fi
    fi
done

if [ $MISSING_COUNT -gt 0 ]; then
    echo -e "\n\033[0;31m[FAILED]\033[0m $MISSING_COUNT files have missing dependencies."
    echo "Please add missing packages to dependencies/apt.txt (with # runtime comment)."
    exit 1
else
    echo -e "\n\033[0;32m[PASSED]\033[0m All runtime dependencies are satisfied."
    exit 0
fi
