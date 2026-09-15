import SwiftUI

private struct WorkflowExecutionQueueKey: EnvironmentKey {
    static let defaultValue: BuiltInAutomationExecutionQueue? = nil
}

extension EnvironmentValues {
    /// The composition's queue is shared by Settings and panel editors.
    /// A preview/test without an application composition may own its own queue.
    var workflowExecutionQueue: BuiltInAutomationExecutionQueue? {
        get { self[WorkflowExecutionQueueKey.self] }
        set { self[WorkflowExecutionQueueKey.self] = newValue }
    }
}
