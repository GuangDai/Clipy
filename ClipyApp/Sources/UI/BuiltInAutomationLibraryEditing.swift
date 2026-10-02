import Foundation

extension BuiltInAutomationWorkflow {
    /// A copy starts as a manual draft, including when its original responds to
    /// new copies. Saving a duplicate must not enable unattended effects.
    func duplicated(named name: String) -> Self {
        Self(name: name, steps: steps.map(BuiltInAutomationStepEditing.copyWithNewIDs),
             trigger: .manual, scope: scope)
    }
}
