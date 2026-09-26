import Foundation

extension BuiltInAutomationWorkflow {
    /// A copy starts as a manual draft, including when its original responds to
    /// new copies. Saving a duplicate must not enable unattended effects.
    func duplicated(named name: String) -> Self {
        func duplicateSteps(_ steps: [BuiltInAutomationStep]) -> [BuiltInAutomationStep] {
            steps.map { original in
                var step = original
                step.id = UUID()
                step.thenSteps = duplicateSteps(original.thenSteps)
                step.otherwiseSteps = duplicateSteps(original.otherwiseSteps)
                return step
            }
        }
        return Self(name: name, steps: duplicateSteps(steps), trigger: .manual, scope: scope)
    }
}
