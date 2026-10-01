import Foundation
import Testing
@testable import MyHub

/// Vectors from AWS's Signature Version 4 documentation and test suite
/// (credentials AKIDEXAMPLE / wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY,
/// 2015-08-30T12:36:00Z, us-east-1).
@Suite struct SigV4Tests {
    let credentials = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secret: Redacted("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), sessionToken: nil)
    let date = Date(timeIntervalSince1970: 1_440_938_160) // 20150830T123600Z

    func signature(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")?.components(separatedBy: "Signature=").last
    }

    @Test func iamListUsersExample() {
        var request = URLRequest(url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!)
        request.httpMethod = "GET"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let signed = SigV4.sign(request, credentials: credentials, region: "us-east-1", service: "iam", now: date)
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(signature(signed) == "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
        #expect(signed.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=content-type;host;x-amz-date") == true)
    }

    @Test func getVanilla() {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        let signed = SigV4.sign(request, credentials: credentials, region: "us-east-1", service: "service", now: date)
        #expect(signature(signed) == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func sessionTokenIsSentAndSigned() {
        let temporary = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secret: credentials.secret, sessionToken: Redacted("TOKEN"))
        var request = URLRequest(url: URL(string: "https://monitoring.us-east-1.amazonaws.com/")!)
        request.httpMethod = "POST"
        let signed = SigV4.sign(request, credentials: temporary, region: "us-east-1", service: "monitoring", now: date)
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Security-Token") == "TOKEN")
        #expect(signed.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-security-token") == true)
    }

    @Test func encodesPerRFC3986() {
        #expect(SigV4.encode("a b/c~d*") == "a%20b%2Fc~d%2A")
    }
}
