import Foundation
import PromiseKit
import CoreLocation

public struct SensorObserverUpdate {
    public let sensors: Guarantee<[WebhookSensor]>
    public let on: Date

    internal init(sensors: Guarantee<[WebhookSensor]>) {
        self.sensors = sensors
        self.on = Current.date()
    }
}

public protocol SensorObserver: AnyObject {
    func sensorContainer(
        _ container: SensorContainer,
        didUpdate update: SensorObserverUpdate
    )
    func sensorContainerDidSignalForUpdate(
        _ container: SensorContainer
    )
}

public class SensorContainer {
    private var providers = [SensorProvider.Type]()
    private var observers = NSHashTable<AnyObject>(options: .weakMemory)
    private var providerDependencies: SensorProviderDependencies

    init() {
        self.providerDependencies = SensorProviderDependencies()
        self.providerDependencies.updateSignalHandler = { [weak self] type in
            self?.updateSignaled(from: type)
        }
    }

    public func register(provider: SensorProvider.Type) {
        providers.append(provider)
    }

    public func register(observer: SensorObserver) {
        observers.add(observer)

        if let lastUpdate = lastUpdate {
            observer.sensorContainer(self, didUpdate: lastUpdate)
        }
    }

    public func unregister(observer: SensorObserver) {
        observers.remove(observer)
    }

    private var lastUpdate: SensorObserverUpdate? {
        didSet {
            guard let lastUpdate = lastUpdate else { return }
            observers
                .allObjects
                .compactMap { $0 as? SensorObserver }
                .forEach { $0.sensorContainer(self, didUpdate: lastUpdate) }
        }
    }

    internal func sensors(
        reason: SensorProviderRequest.Reason,
        location: CLLocation? = nil
    ) -> Guarantee<[WebhookSensor]> {
        let request = SensorProviderRequest(
            reason: reason,
            dependencies: providerDependencies,
            location: location
        )

        let sensors = firstly {
            let promises = providers
                .map { providerType in providerType.init(request: request) }
                .map { provider in provider.sensors().map { ($0, provider) } }

            return when(resolved: promises)
        }.map { (sensors: [Result<([WebhookSensor], SensorProvider)>]) -> [WebhookSensor] in
            // now that we are done, we don't need to keep a strong reference to the provider instance anymore
            sensors.compactMap { (result: Result<([WebhookSensor], SensorProvider)>) -> [WebhookSensor]? in
                if case .fulfilled(let value) = result {
                    return value.0
                } else {
                    return nil
                }
            }.flatMap { $0 }
        }

        switch request.reason {
        case .trigger:
            // only store when we know we're sending the maximum kind of data
            lastUpdate = .init(sensors: sensors)
        case .registration:
            break
        }

        return sensors
    }

    private func updateSignaled(from type: SensorProvider.Type) {
        Current.Log.info("live update triggering from \(type)")

        observers
            .allObjects
            .compactMap { $0 as? SensorObserver }
            .forEach { $0.sensorContainerDidSignalForUpdate(self) }
    }
}
