import Foundation
import Yams

struct InputGuard {
    let job, step, input, value: String

    // A step guarded by a simple equality can confirm a value when it runs.
    // Follow direct job-output forwarding only when the producing step consists
    // of a single assignment of that input to GITHUB_OUTPUT.
    static func extract(root: Node?, inputs: [WorkflowInput]) -> [InputGuard] {
        guard let jobs = root?["jobs"]?.mapping else { return [] }
        var bindings: [String: String] = [:]
        for spec in inputs {
            bindings["inputs." + spec.id] = spec.id
            bindings["github.event.inputs." + spec.id] = spec.id
        }
        for (jobKey, job) in jobs {
            guard let jobID = jobKey.string, let outputs = job["outputs"]?.mapping,
                  let steps = job["steps"]?.sequence else { continue }
            for step in steps {
                guard let id = step["id"]?.string, let script = step["run"]?.string,
                      let match = script.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of:
                        #/^echo\s+"([\w-]+)=\$\{\{\s*(inputs\.[\w-]+)(?:\s*\|\|\s*'[^']*')?\s*\}\}"\s*>>\s*"?\$GITHUB_OUTPUT"?$/#),
                      let input = bindings[String(match.2)] else { continue }
                for (name, val) in outputs {
                    guard let key = name.string,
                          val.string?.replacingOccurrences(of: " ", with: "") == "${{steps." + id + ".outputs." + match.1 + "}}" else { continue }
                    bindings["needs." + jobID + ".outputs." + key] = input
                }
            }
        }
        let jobNames = jobs.compactMap { key, job in job["name"]?.string ?? key.string }
        var guards: [InputGuard] = []
        for (key, job) in jobs {
            guard let name = job["name"]?.string ?? key.string, let steps = job["steps"]?.sequence else { continue }
            guard jobNames.filter({ $0 == name }).count == 1 else { continue }
            let stepNames = steps.compactMap { $0["name"]?.string }
            for step in steps {
                guard let stepName = step["name"]?.string, let condition = step["if"]?.string,
                      stepNames.filter({ $0 == stepName }).count == 1 else { continue }
                var test = condition.trimmingCharacters(in: .whitespacesAndNewlines)
                if test.hasPrefix("${{"), test.hasSuffix("}}") {
                    test = test.dropFirst(3).dropLast(2).trimmingCharacters(in: .whitespaces)
                }
                guard let match = test.wholeMatch(of: #/([\w.-]+)\s*==\s*'([^']+)'/#),
                      let input = bindings[String(match.1)],
                      let spec = inputs.first(where: { $0.id == input }),
                      // Equality in Actions ignores case. Only infer a canonical
                      // value if the declaration establishes its exact spelling.
                      let value = spec.options.first(where: { $0 == String(match.2) }),
                      spec.options.filter({ $0.lowercased() == value.lowercased() }).count == 1 else { continue }
                guards.append(InputGuard(job: name, step: stepName, input: input, value: value))
            }
        }
        return guards
    }
}
