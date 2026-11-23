fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    // The encrypted-media C implementation (the same sources CryptoDataSource
    // links) is needed on the desktop ports and on iOS: desktop_media exports
    // the sp_stream_* entry points and the build fails without it.
    if target_os != "windows" && target_os != "linux" && target_os != "macos" && target_os != "ios" {        return;
    }
    let sources = [
        "crypto_core/sp_error.c",
        "crypto_core/sp_stream.c",
        "crypto_core/mp4_cenc.c",
        "crypto_core/sp_aes.c",
        "third_party/tiny_aes/aes.c",
    ];
    let mut build = cc::Build::new();
    build
        .include("../native/crypto_core")
        .std("c11")
        .pic(target_os == "linux")
        .flag_if_supported("/experimental:c11atomics")
        .define("CBC", "0")
        .define("CTR", "0")
        .define("ECB", "1");
    for source in sources {
        let path = format!("../native/{source}");
        println!("cargo:rerun-if-changed={path}");
        build.file(path);
    }
    println!("cargo:rerun-if-changed=../native/crypto_core");
    println!("cargo:rerun-if-changed=../native/third_party/tiny_aes");
    build.compile("sp_crypto_core");
}
