import XCTest
@testable import LazyPDFKit

// No C# twin: the C# takes MD5 and SHA from System.Security.Cryptography. These check the engine's own against
// published vectors and against the digests of a byte pattern at the block and padding boundaries.

final class DigestTests: XCTestCase {
    private func pattern(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 % 251) }
    }

    func test_publishedVectors() {
        XCTAssertEqual(Hex.string(Md5.hash(Array("abc".utf8))).lowercased(), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Hex.string(Md5.hash(Array("message digest".utf8))).lowercased(), "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(Hex.string(Sha1.hash(Array("abc".utf8))).lowercased(), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Hex.string(Sha256.hash(Array("abc".utf8))).lowercased(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hex.string(Sha384.hash(Array("abc".utf8))).lowercased(),
                       "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
        XCTAssertEqual(Hex.string(Sha512.hash(Array("abc".utf8))).lowercased(),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    func test_md5OfPatternsAtBlockBoundaries() {
        for (count, expected) in [
            (0, "d41d8cd98f00b204e9800998ecf8427e"),
            (1, "93b885adfe0da089cdf634904fd59f71"),
            (55, "6912ee65fff2d9f9ce2508cddf8bcda0"),
            (56, "51fdd1acda72405dfdfa03fcb85896d7"),
            (63, "48a6295221902e8e0938f773a7185e72"),
            (64, "b2d3f56bc197fd985d5965079b5e7148"),
            (65, "8bd7053801c768420faf816fadba971c"),
            (111, "4fad3ab7d8546851ec1bb63ea7e6f5a8"),
            (112, "d1fec2ac3715e791ca5f489f300381b3"),
            (128, "37eff01866ba3f538421b30b7cbefcac"),
            (1000, "a24f1e3ef66950e1327f210e3997ba2c"),
        ] as [(Int, String)] {
            XCTAssertEqual(Hex.string(Md5.hash(pattern(count))).lowercased(), expected, "\(count) bytes")
        }
    }

    func test_sha1OfPatternsAtBlockBoundaries() {
        for (count, expected) in [
            (0, "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            (1, "5ba93c9db0cff93f52b521d7420e43f6eda2784f"),
            (55, "8ae2d46729cfe68ff927af5eec9c7d1b66d65ac2"),
            (56, "636e2ec698dac903498e648bd2f3af641d3c88cb"),
            (63, "6d942da0c4392b123528f2905c713a3ce28364bd"),
            (64, "c6138d514ffa2135bfce0ed0b8fac65669917ec7"),
            (65, "69bd728ad6e13cd76ff19751fde427b00e395746"),
            (111, "bc544e24573d592290fdaff8ecf3f7f2b00cd483"),
            (112, "e4ce142d09a84a8645338dd6535cbfaaf800d320"),
            (128, "e6434bc401f98603d7eda504790c98c67385d535"),
            (1000, "c9c960a0b925474fab83942cc27d504fc24ac37b"),
        ] as [(Int, String)] {
            XCTAssertEqual(Hex.string(Sha1.hash(pattern(count))).lowercased(), expected, "\(count) bytes")
        }
    }

    func test_sha256OfPatternsAtBlockBoundaries() {
        for (count, expected) in [
            (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (55, "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59"),
            (56, "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562"),
            (63, "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488"),
            (64, "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108"),
            (111, "60780e9451bdc43cf4530ffc95cbb0c4eb24dae2c39f55f334d679e076c08065"),
            (112, "09373f127d34e61dbbaa8bc4499c87074f2ddb10e1b465f506d7d70a15011979"),
            (128, "471fb943aa23c511f6f72f8d1652d9c880cfa392ad80503120547703e56a2be5"),
            (1000, "4e4c294b331f7a2099a379bec34b9f9fc03dc46ab465d998f4d683da53487e6d"),
        ] as [(Int, String)] {
            XCTAssertEqual(Hex.string(Sha256.hash(pattern(count))).lowercased(), expected, "\(count) bytes")
        }
    }

    func test_sha384OfPatternsAtBlockBoundaries() {
        for (count, expected) in [
            (0, "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"),
            (55, "dcedb6b590edb4efa849c801e6b6490657a5c1e64f69269f5f63c9267f6223de24cea7aaa6b267d9bcecc15147b6c875"),
            (56, "7b9132d597b8873ad55bbc30f18ed3f2c9f340e7de69fb5774056c71a06d9bc2b14137e9e1c68b6b645fed28b188249d"),
            (63, "dd66b519f51a925814407a449c60b34c553d7652d41783ee903a810a4c9f833b8181c91c7f12283eacd6a5f8a2639ddf"),
            (64, "9f2c9eb7116b3d7a4ba84a74a4d4eff8a5efcf54b6d7b662693c38577914c73a214766f0a175339bb0895a863824fc0a"),
            (111, "f5f9fe110d809d34029de262a01b208356caec6e054c7f926b2591f6c9780579d4b59f5578c6f531a84f158a33660cef"),
            (112, "33ba080ec0ccb378e4e95fed3b26c23aa1a280476e007519ee47f60cd9c5c8a65d627259a9aa2fd33ca06d3c14ee5548"),
            (128, "ca2385773319124534111a36d0581fc3f00815e907034b90cff9c3a861e126a741d5dfcff65a417b6d7296863ac0ec17"),
            (1000, "7a2f8c7f12344964a13cb9260492b845e56615d6152b9eb9e54b580fc88405e64f31813bfda10de2a642fdf1676c61b4"),
        ] as [(Int, String)] {
            XCTAssertEqual(Hex.string(Sha384.hash(pattern(count))).lowercased(), expected, "\(count) bytes")
        }
    }

    func test_sha512OfPatternsAtBlockBoundaries() {
        for (count, expected) in [
            (0, "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"),
            (55, "6856647f269c2ee3d8128f0b25427659d880641ef343300dd3cd4679168f58d6527fda70b4ebc854e2065e172b7d58c1536992c0810599259ba84a2b40c65414"),
            (56, "8b12b2f6fe400a51d29656e2b8c42a1bbfe6fcf3e425da430db05d1a2dda14790dee20fa8b22d8762afffe4988a5c98a4430d22a17e41e23d90fa61ab75671a9"),
            (63, "9dc9c5598e55dc42955695320839788e353f1d7f6ba74df74c80a8a52f463c0697f57f68835d1418f4ce9b6530cd79bd0f4c6f7e13c93feb1218c0b65c2c0561"),
            (64, "ee4320ebaf3fdb4f2c832b137200c08e235e0fa7bbd0eb1740c7063ba8a0d151da77e003398e1714a955d475b05e3e950b639503b452ec185de4229bc4873949"),
            (111, "a1a111449b198d9b1f538bad7f3fc1022b3a5b1a5e90a0bc860de8512746cbc31599e6c834de3a3235327af0b51ff57bf7acf1974a73014d9c3953812edc7c8d"),
            (112, "c5fbd731d19d2ae1180f001be72c2c1aaba1d7b094b3748880e24593b8e117a750e11c1bd867cc2f96dace8c8b74abd2d5c4f236be444e77d30d1916174070b9"),
            (128, "1dffd5e3adb71d45d2245939665521ae001a317a03720a45732ba1900ca3b8351fc5c9b4ca513eba6f80bc7b1d1fdad4abd13491cb824d61b08d8c0e1561b3f7"),
            (1000, "5096498d96f50f9a137c4db5b8b0cd38383ad55350fb5a98805fedc31fa1262f1f0cf4d6f12d7ecd8dedd933a4c9126344fe22e937a8ad35fdeae1e876ae698b"),
        ] as [(Int, String)] {
            XCTAssertEqual(Hex.string(Sha512.hash(pattern(count))).lowercased(), expected, "\(count) bytes")
        }
    }
}
