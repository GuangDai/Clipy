import Dispatch

extension AppDelegate {
    /// TIER-5: one app-owned source, delivered directly to the existing panel
    /// surface on MainActor. No History action or retention sweep is involved.
    func installMemoryPressureObservation() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.memoryPressureSource else { return }
                self.receiveMemoryPressure(source.data)
            }
        }
#if DEBUG
        source.setRegistrationHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.memoryPressureRegistrationCountForTesting += 1
            }
        }
        source.setCancelHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.memoryPressureCancellationCountForTesting += 1
            }
        }
#endif
        source.activate()
    }

    func removeMemoryPressureObservation() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    func receiveMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
        // Dispatch may coalesce flags. Honor the strongest supplied pressure
        // rather than treating a coalesced normal flag as recovery.
        let pressure: DisplayMemoryPressure
        if events.contains(.critical) { pressure = .critical }
        else if events.contains(.warning) {
            pressure = displayMemoryPressure == .critical ? .critical : .warning
        }
        else if events.contains(.normal) { pressure = .normal }
        else { return }
        displayMemoryPressure = pressure
        panelSurfaceState?.respondToMemoryPressure(pressure)
    }
}
