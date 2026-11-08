/// Consumes scripted results in order. Once one entry is left, it repeats.
enum ScriptedReadings {
    static func next<T>(_ script: inout [Result<T, MetricIssue>]) throws(MetricIssue) -> T {
        guard let entry = script.first else {
            throw .kernelCallFailed(call: "mock: no scripted reading", code: 0)
        }
        if script.count > 1 { script.removeFirst() }
        switch entry {
        case let .success(value):
            return value
        case let .failure(issue):
            throw issue
        }
    }
}
