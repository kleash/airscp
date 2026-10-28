import Foundation

/// Import from ~/.aws: the AWS CLI's profiles (`credentials` and `config`) that have a key of their own, with their
/// region and endpoint_url. Profiles that sign in with single sign-on, run a program for their keys, or take on a role
/// can't be used as they are: they come with the reason.
public enum AWSProfiles {
    public struct Profile: Equatable {
        public var name: String
        public var accessKeyID = ""
        public var secret = ""
        public var token = ""
        public var region = ""
        public var endpoint = ""
        public var pathStyle = false
        /// Why it can't be imported; nil when it can.
        public var problem: String?
    }

    /// $AIRSCP_AWS_DIR (tests), else ~/.aws.
    public static var folder: String {
        if let dir = Env.value("AWS_DIR"), !dir.isEmpty { return dir }
        return FolderAccess.home + "/.aws"
    }

    /// The profiles in `folder`'s credentials and config files, by name.
    public static func profiles(in folder: String = folder) -> [Profile] {
        func read(_ name: String) -> String { (try? String(contentsOfFile: folder + "/" + name, encoding: .utf8)) ?? "" }
        var values = sections(read("credentials"), config: false)
        for (name, settings) in sections(read("config"), config: true) { values[name, default: [:]].merge(settings) { kept, _ in kept } }
        return values.keys.sorted().map { name in
            let settings = values[name] ?? [:]
            var profile = Profile(name: name, accessKeyID: settings["aws_access_key_id"] ?? "",
                                  secret: settings["aws_secret_access_key"] ?? "", token: settings["aws_session_token"] ?? "",
                                  region: settings["region"] ?? "",
                                  endpoint: settings["s3.endpoint_url"] ?? settings["endpoint_url"] ?? "",
                                  pathStyle: settings["s3.addressing_style"] == "path")
            if settings.keys.contains(where: { $0.hasPrefix("sso_") }) {
                profile.problem = "signs in with single sign-on (SSO), which AirSCP doesn't do: make an access key for it"
            } else if settings["credential_process"] != nil {
                profile.problem = "gets its keys from a program (credential_process), which AirSCP doesn't run"
            } else if settings["role_arn"] != nil {
                profile.problem = "takes on a role (role_arn), which AirSCP doesn't do: use the keys of a user"
            } else if profile.accessKeyID.isEmpty || profile.secret.isEmpty {
                profile.problem = "has no access key and secret key"
            }
            return profile
        }
    }

    /// An INI file's sections and their settings ("s3.endpoint_url" for a setting nested under "s3 ="); config's
    /// sections are "default" and "profile <name>" (others, such as sso-session, are left out).
    static func sections(_ text: String, config: Bool) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?, parent: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                var name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if config {
                    if name.hasPrefix("profile ") {
                        name = name.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
                    } else if name != "default" {
                        section = nil
                        continue
                    }
                }
                section = name
                parent = nil
                continue
            }
            guard let section, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let nested = raw.first?.isWhitespace == true && parent != nil
            if value.isEmpty && !nested {
                parent = key  // "s3 =": the indented lines below are its settings
                continue
            }
            if !nested { parent = nil }
            result[section, default: [:]][nested ? parent! + "." + key : key] = value
        }
        return result
    }
}
