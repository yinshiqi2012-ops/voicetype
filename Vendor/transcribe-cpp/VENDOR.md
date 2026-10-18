# vendored: transcribe.cpp Swift 绑定

- 上游：https://github.com/handy-computer/transcribe.cpp （MIT）
- 版本：0.4.0
- 只保留了 `bindings/swift/Sources/TranscribeCpp` 与 macOS 可用的 xcframework，
  去掉了上游的 5 个示例可执行目标与测试目标，避免拖慢本项目的构建。

## 重新生成 xcframework

```bash
git clone --depth 1 https://github.com/handy-computer/transcribe.cpp /tmp/tcpp
cd /tmp/tcpp
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8
bash scripts/ci/build_xcframework.sh
cp -R bindings/swift/build-apple/TranscribeCpp.xcframework \
      <本目录>/build-apple/
```
