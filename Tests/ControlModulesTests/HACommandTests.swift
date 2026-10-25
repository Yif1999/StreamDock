import Testing
@testable import ControlModules

struct HACommandTests {
    private func entity(_ domain: String, state: String = "on", _ attributes: HAData) -> HAEntity {
        HAEntity(.object(["entity_id": .string("\(domain).fixture"), "state": .string(state), "attributes": .object(attributes)]))!
    }
    private func command(_ action: HAAction, _ entity: HAEntity) -> HACommand? {
        let names = ["turn_on", "turn_off", "toggle", "set_temperature", "set_hvac_mode", "set_percentage", "oscillate", "set_preset_mode"]
        return HACommand.make(action: action, entity: entity, services: [entity.domain: .object(Dictionary(uniqueKeysWithValues: names.map { ($0, .object([:])) }))])
    }
    @Test func powerReadingsAreWholeWattsThenKilowatts() {
        func reading(_ state: String, _ unit: String) -> String? {
            entity("sensor", state: state, ["unit_of_measurement": .string(unit), "device_class": .string("power")]).powerText
        }
        #expect(reading("86.4", "W") == "86W")
        #expect(reading("999.6", "W") == "1.0kW")
        #expect(reading("1.46", "kW") == "1.5kW")
        #expect(reading("-0.2", "W") == "0W")
        #expect(reading("unavailable", "W") == nil)
        #expect(reading("3", "kWh") == nil) // Energy, not power.
        #expect(entity("sensor", state: "86.4", ["unit_of_measurement": .string("W")]).keyState == "86W")
    }
    @Test func climateTemperatureHonorsStepLimitsAndPowerState() {
        let attrs: HAData = ["temperature": .number(29.5), "min_temp": .number(16), "max_temp": .number(30), "target_temp_step": .number(0.5), "supported_features": .number(425), "hvac_modes": .array([.string("off"), .string("cool"), .string("heat")])]
        let climate = entity("climate", state: "cool", attrs)
        #expect(command(.temperatureUp, climate)?.data["temperature"] == .number(30))
        #expect(command(.temperatureDown, climate)?.data["temperature"] == .number(29))
        #expect(command(.climateMode, climate)?.data["hvac_mode"] == .string("heat"))
        #expect(command(.toggle, climate)?.service == "turn_off")
        let off = entity("climate", state: "off", attrs)
        #expect(command(.toggle, off)?.service == "turn_on")
        #expect(command(.temperatureUp, off) == nil)
        var maxed = attrs; maxed["temperature"] = .number(30)
        #expect(command(.temperatureUp, entity("climate", state: "cool", maxed)) == nil)
    }
    @Test func fanUsesDeviceSpeedStepsAndReportedModes() {
        let fan = entity("fan", ["percentage": .number(25), "percentage_step": .number(25), "supported_features": .number(59), "oscillating": .bool(true), "preset_modes": .array([.string("直吹风"), .string("自然风")]), "preset_mode": .string("直吹风")])
        #expect(command(.fanSpeedUp, fan)?.data["percentage"] == .number(50))
        #expect(command(.fanSpeedDown, fan) == nil) // Lowest speed must not turn the fan off.
        #expect(command(.fanOscillate, fan)?.data["oscillating"] == .bool(false))
        #expect(command(.fanPreset, fan)?.data["preset_mode"] == .string("自然风"))
        #expect(command(.fanSpeedUp, entity("fan", ["supported_features": .number(0)])) == nil)
    }
    @Test func lightTemperatureUsesKelvinAndDeviceBounds() {
        var attrs: HAData = ["supported_color_modes": .array([.string("color_temp")]), "color_temp_kelvin": .number(2800), "min_color_temp_kelvin": .number(2700), "max_color_temp_kelvin": .number(6500)]
        #expect(command(.warmer, entity("light", attrs))?.data["color_temp_kelvin"] == .number(2700))
        #expect(command(.cooler, entity("light", attrs))?.data["color_temp_kelvin"] == .number(3000))
        attrs["color_temp_kelvin"] = .number(6500)
        #expect(command(.cooler, entity("light", attrs)) == nil)
        #expect(command(.warmer, entity("light", state: "off", attrs)) == nil)
    }
    @Test func protectedPowerUsesExplicitOnOffNeverToggle() {
        #expect(command(.safePower, entity("switch", [:]))?.service == "turn_off")
        #expect(command(.safePower, entity("switch", state: "off", [:]))?.service == "turn_on")
        #expect(command(.safePower, entity("switch", state: "unavailable", [:])) == nil)
    }
}
