# 🎭 패키지 오버레이 (Package Overlay)

이 디렉토리는 `vcs`로 다운로드 받은 외부 ROS 패키지들의 설정을 덮어쓰기(Overlay) 위한 공간입니다.
외부 패키지의 빌드 순서 문제가 있거나, 일부 패키지를 빌드에서 제외하고 싶을 때 유용합니다.

## 사용 방법

`dependencies/overlay/` 디렉토리 내부에 **클론된 패키지의 구조를 그대로 모방**하여 파일들을 배치하세요.
컨테이너 내 터미널에서 `sync_deps` 명렁어를 실행하면, `vcs import`가 완료된 후 이 폴더의 내용이 `src/` 경로에 덮어씌워집니다.

### 예시 1: 빌드 순서 변경 (`package.xml` 덮어쓰기)

빌드 순서를 조정하기 위해 외부 패키지의 `package.xml`에 특정 `<depend>` 태그를 추가해야 할 경우:

1. `dependencies/overlay/대상_저장소명/package.xml` 위치에 수정된 파일을 준비합니다.
2. `sync_deps` 실행 시 원본 `package.xml`이 오버레이 파일로 교체됩니다.

### 예시 2: 특정 디렉토리 빌드 제외 (`COLCON_IGNORE`, `CATKIN_IGNORE`)

외부 저장소에서 불필요한 예제(example)나 서브 패키지도 함께 다운로드 되었을 때, 빌드 시간을 줄이고 의존성 에러를 피하려면:

1. `dependencies/overlay/대상_저장소명/불필요한_서브패키지/COLCON_IGNORE` (빈 파일) 을 생성해둡니다.
2. 컴파일러가 해당 디렉토리를 무시하고 빌드를 건너뜁니다.
