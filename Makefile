.PHONY: build test clean

build::
	swift build -c release --arch arm64 --arch x86_64
	cp -f "$$(swift build --show-bin-path -c release --arch arm64 --arch x86_64)/wechattweak" ./wechattweak
	cp -f "$$(swift build --show-bin-path -c release --arch arm64 --arch x86_64)/libWeChatTweakRuntime.dylib" ./libWeChatTweakRuntime.dylib

clean::
	rm -rf .build
	rm -f wechattweak
	rm -f libWeChatTweakRuntime.dylib

test::
	swift test
	sh Tests/Native/run.sh
