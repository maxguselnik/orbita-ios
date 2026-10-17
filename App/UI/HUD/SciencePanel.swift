import OrbitPhysics
import SwiftUI

/// Вкладка «Наука» выдвижной панели (макет «Орбита: панель науки»): где корабль, эксперименты с ценностью
/// или причиной недоступности, результаты на борту с удалением. Наука начисляется при возврате на Терру
/// (`GameFlow.finishFlight`); здесь только сбор и предпросмотр по архиву.
struct SciencePanel: View {
    let model: FlightHUDModel
    var singleColumn = false

    var body: some View {
        let st = model.telemetry.science
        let archive = model.scienceArchive
        let stored = st.data
        let values = archive.preview(stored)
        VStack(alignment: .leading, spacing: 8) {
            place(st, archive: archive)

            let experiments = st.experiments
            if experiments.isEmpty {
                Text("На корабле нет экипажа и приборов. Приборы — во вкладке «Наука» каталога ангара.")
                    .font(.system(size: HUDFont.small, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: singleColumn ? 1 : 2), spacing: 6) {
                    ForEach(experiments, id: \.self) { e in
                        actionButton(e, st: st, archive: archive)
                    }
                }
            }

            if !st.stored.isEmpty {
                Text(storedTitle(st).uppercased())
                    .font(.system(size: HUDFont.caption, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(HUDStyle.secondaryText)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(st.stored.enumerated()), id: \.element.data.id) { i, item in
                            dataRow(item, value: i < values.count ? values[i] : 0)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(st.recoverable ? "Капсула на Терре: наука начислится по итогам полёта."
                                    : "Наука начисляется, когда капсула вернётся на Терру.")
                    .font(.system(size: HUDFont.caption, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !stored.isEmpty {
                    Text("\(Self.format(values.reduce(0, +))) ⚛")
                        .font(.system(size: HUDFont.small, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// «⚛ Терра · ближний космос  [новое]».
    private func place(_ st: ScienceStatus, archive: ScienceArchive) -> some View {
        let title = st.situation.map { ScienceSubjectID(experiment: .crewReport, body: st.body, situation: $0).placeTitle }
            ?? "Здесь наука невозможна"
        let fresh = st.experiments.contains { e in
            st.subject(e).map { archive.valueOfNew($0, stored: st.data) > 0 } ?? false
        }
        return HStack(spacing: 6) {
            Image(systemName: "atom").font(.system(size: HUDFont.body, weight: .semibold))
            Text(title)
                .font(.system(size: HUDFont.body, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if st.situation != nil, !st.experiments.isEmpty {
                Text(fresh ? "новое" : "собрано")
                    .font(.system(size: HUDFont.caption, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(fresh ? Color(red: 0.05, green: 0.16, blue: 0.07) : HUDStyle.secondaryText)
                    .background(fresh ? HUDPalette.green : Color.white.opacity(0.14), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Кнопка эксперимента: «Термометр  +8 ⚛», недоступный — серый с причиной.
    private func actionButton(_ e: ExperimentID, st: ScienceStatus, archive: ScienceArchive) -> some View {
        let subject = st.subject(e)
        let value = subject.map { archive.valueOfNew($0, stored: st.data) } ?? 0
        let reason: String? = st.blocker(e).map { b in b == .notHere ? e.whereItWorks : b.text }
            ?? (value > 0 ? nil : "уже на борту")
        let enabled = subject != nil
        return Button {
            model.send(.collectScience(e))
        } label: {
            HStack(spacing: 4) {
                Text(e.title)
                    .font(.system(size: HUDFont.body, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(reason ?? "+\(Self.format(value)) ⚛")
                    .font(.system(size: reason == nil ? HUDFont.body : HUDFont.caption, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
            .foregroundStyle(enabled && reason == nil ? HUDPalette.accentText : HUDStyle.secondaryText)
            .background(enabled && reason == nil ? HUDPalette.accent : Color(red: 0.16, green: 0.19, blue: 0.25),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(e.title + (reason.map { ", " + $0 } ?? ", плюс \(Self.format(value)) науки"))
    }

    private func dataRow(_ item: StoredScience, value: Double) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.data.subject.experiment.title)
                    .font(.system(size: HUDFont.small, weight: .bold))
                    .lineLimit(1)
                Text(item.data.subject.placeTitle)
                    .font(.system(size: HUDFont.caption, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Text(Self.format(value))
                .font(.system(size: HUDFont.small, weight: .heavy).monospacedDigit())
                .foregroundStyle(value > 0 ? HUDPalette.accent : HUDStyle.secondaryText)
            Button {
                model.send(.discardScience(id: item.data.id))
            } label: {
                Image(systemName: "trash").font(.system(size: HUDFont.body, weight: .semibold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Удалить: \(item.data.subject.experiment.title), \(item.data.subject.placeTitle)")
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// «На борту · Капсула К-1» (или несколько мест хранения через запятую).
    private func storedTitle(_ st: ScienceStatus) -> String {
        var names: [String] = []
        for p in st.stored.map(\.part) where !names.contains(p.spec.name) { names.append(p.spec.name) }
        return "На борту · " + names.joined(separator: ", ")
    }

    /// 2.4 → «2.4», 8 → «8».
    static func format(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}
