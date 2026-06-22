// HubFirebaseRemoteConfig — интеграция Firebase Remote Config для HubSDK.
//
// Использование:
//   1. Зарегистрируйте интеграцию в HubSDKCore и запустите хаб:
//        let rc = HubFirebaseRemoteConfigIntegration()
//        hub.register(rc); hub.run(with: app)
//
//   2. Дождитесь фетча и читайте значения через provider:
//        await rc.provider.fetchAndActivate()
//        let limit = rc.provider.int(forKey: "free_tap_limit") ?? 5
//
// Требования: GoogleService-Info.plist в бандле приложения.
// Если плист отсутствует — Firebase не конфигурируется; все геттеры
// возвращают nil, вызывающая сторона берёт свои дефолты.

import Foundation
import FirebaseCore
import FirebaseRemoteConfig
import HubIntegrationCore
import HubSDKCore

// MARK: - Протокол провайдера

/// Типизированный доступ к значениям Firebase Remote Config.
/// Все методы синхронны — работают с уже активированным снапшотом.
/// Возвращают nil, если ключа нет или Firebase недоступен.
public protocol HubRemoteConfigProviding: Sendable {
    func string(forKey key: String) -> String?
    func int(forKey key: String) -> Int?
    func bool(forKey key: String) -> Bool?
    func double(forKey key: String) -> Double?

    /// Форс-обновление: фетч + активация. Безопасно вызывать многократно.
    func fetchAndActivate() async
}

// MARK: - Внутренняя реализация провайдера

/// Реализация провайдера. @unchecked Sendable — изоляция обеспечена структурой:
/// все обращения к RemoteConfig идут через thread-safe Firebase SDK.
final class HubFirebaseRemoteConfigProvider: HubRemoteConfigProviding, @unchecked Sendable {

    func string(forKey key: String) -> String? {
        guard isFirebaseConfigured() else { return nil }
        let value = RemoteConfig.remoteConfig().configValue(forKey: key)
        // Firebase возвращает пустую строку / nil для несуществующих ключей
        guard let str = value.stringValue, !str.isEmpty else { return nil }
        return str
    }

    func int(forKey key: String) -> Int? {
        guard isFirebaseConfigured() else { return nil }
        guard keyExists(key) else { return nil }
        return RemoteConfig.remoteConfig().configValue(forKey: key).numberValue.intValue
    }

    func bool(forKey key: String) -> Bool? {
        guard isFirebaseConfigured() else { return nil }
        guard keyExists(key) else { return nil }
        return RemoteConfig.remoteConfig().configValue(forKey: key).boolValue
    }

    func double(forKey key: String) -> Double? {
        guard isFirebaseConfigured() else { return nil }
        guard keyExists(key) else { return nil }
        return RemoteConfig.remoteConfig().configValue(forKey: key).numberValue.doubleValue
    }

    func fetchAndActivate() async {
        guard isFirebaseConfigured() else { return }
        _ = try? await RemoteConfig.remoteConfig().fetchAndActivate()
    }

    // MARK: - Private

    private func isFirebaseConfigured() -> Bool {
        FirebaseApp.app() != nil
    }

    /// Проверяет наличие ключа в активированном конфиге.
    /// Firebase SDK возвращает пустую строку / nil для несуществующих ключей.
    private func keyExists(_ key: String) -> Bool {
        let value = RemoteConfig.remoteConfig().configValue(forKey: key)
        return value.stringValue.map { !$0.isEmpty } ?? false
    }
}

// MARK: - Интеграция

/// Интеграция Firebase Remote Config. Регистрируется в HubSDKCore и запускается
/// через `start()`. Готовность и значения получают через `await provider.fetchAndActivate()`.
@MainActor
public class HubFirebaseRemoteConfigIntegration: HubDependencyIntegration {

    public static var name: String { "FirebaseRemoteConfig" }

    private let remoteConfigProvider = HubFirebaseRemoteConfigProvider()
    private let minimumFetchInterval: TimeInterval

    public var provider: HubRemoteConfigProviding { remoteConfigProvider }

    // MARK: Init

    /// - Parameter minimumFetchInterval: минимальный интервал между фетчами в секундах.
    ///   Для dev-окружения передавайте 0. Прод-дефолт Firebase — 43200 (12 часов).
    public init(minimumFetchInterval: TimeInterval = 0) {
        self.minimumFetchInterval = minimumFetchInterval
    }

    // MARK: HubDependencyIntegration

    public func start() {
        // Конфигурируем Firebase только если ещё не сконфигурирован
        // (например, HubFirebaseIntegration уже вызвала configure)
        if FirebaseApp.app() == nil {
            guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
                // Плист отсутствует — грейсфул режим: RC недоступен, но не крашим
                return
            }
            FirebaseApp.configure()
        }

        // Настраиваем интервал фетча
        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = minimumFetchInterval
        RemoteConfig.remoteConfig().configSettings = settings
    }
}
