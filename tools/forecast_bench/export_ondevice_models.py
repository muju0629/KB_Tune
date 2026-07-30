"""검증된 LightGBM 중앙값·q75·Hazard를 앱용 중립 JSON으로 내보낸다.

원거래나 사용자 식별자는 포함하지 않는다. 모델 트리, 피처 순서, 인구 사전값,
확률 보정 계수와 Python↔Swift 일치 검사용 고정 입력만 저장한다.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np

import active_feedback_bench as amount_base
import calibrated_risk_conformal_holdout as amount_experiment
import card_calendar_bench as hazard_generator
import hazard_calendar_holdout_12week as hazard_experiment
import personal_bayes_feedback_bench as amount_generator
import risk_gated_personalization_12week as amount_scenarios


HERE = Path(__file__).parent
APP_OUT = HERE.parents[1] / "KB_Tune/ForecastModels.json"
GOLDEN_OUT = HERE.parents[1] / "KB_TuneTests/ForecastGolden.json"
MODEL_VERSION = "forecast-synth-v1-2026-07-30"
FEATURE_VERSION = "forecast-feature-v1"
AMOUNT_SEED = 20261221
HAZARD_SEED = 20270121


def flatten_tree(structure: dict) -> list[dict]:
    nodes: list[dict] = []

    def visit(node: dict) -> int:
        index = len(nodes)
        nodes.append({})
        if "leaf_value" in node:
            nodes[index] = {"v": float(node["leaf_value"])}
            return index
        left = visit(node["left_child"])
        right = visit(node["right_child"])
        nodes[index] = {
            "f": int(node["split_feature"]),
            "t": float(node["threshold"]),
            "l": left,
            "r": right,
            "d": bool(node.get("default_left", True)),
        }
        return index

    visit(structure)
    return nodes


def export_booster(model, transform: str) -> dict:
    booster = model.booster_
    dumped = booster.dump_model()
    return {
        "features": list(booster.feature_name()),
        "transform": transform,
        "trees": [flatten_tree(tree["tree_structure"]) for tree in dumped["tree_info"]],
    }


def evaluate(model: dict, row: dict[str, float]) -> float:
    values = [float(row.get(name, 0.0)) for name in model["features"]]
    total = 0.0
    for tree in model["trees"]:
        index = 0
        while "v" not in tree[index]:
            node = tree[index]
            value = values[node["f"]]
            go_left = node["d"] if not np.isfinite(value) else value <= node["t"]
            index = node["l"] if go_left else node["r"]
        total += tree[index]["v"]
    if model["transform"] == "sigmoid":
        return float(1 / (1 + np.exp(-total)))
    return float(total)


def amount_models() -> tuple[dict, dict]:
    amount_experiment.set_seed(AMOUNT_SEED)
    calibration = json.loads(amount_experiment.CALIBRATION.read_text(encoding="utf-8"))
    true_tx, calendar, _ = amount_generator.generate_persistent(calibration)
    true_tx = amount_scenarios.apply_scenario(true_tx, {"scenario": "기본", "seed": AMOUNT_SEED})
    observed = amount_base.add_observation_noise(true_tx)
    target_cat, _ = amount_base.true_targets(true_tx)
    pop_amount, pop_occurrence = amount_base.population_stats(true_tx)
    index = amount_base.make_index(observed, calendar)

    X_train, _, y_train = amount_base.build_rows(
        amount_experiment.TRAIN_PEOPLE,
        range(amount_base.HISTORY_WEEKS, hazard_generator.FIRST_TEST_WEEK),
        index, target_cat, pop_amount, pop_occurrence,
    )
    fitted, quantiles = amount_experiment.fit_seed_models(AMOUNT_SEED, X_train, y_train)
    lightgbm = fitted["LightGBM"]
    q75 = quantiles["안전 q75"]

    X_cal, _, y_cal = amount_base.build_rows(
        amount_experiment.CALIBRATION_PEOPLE,
        range(hazard_generator.FIRST_TEST_WEEK - 8, hazard_generator.FIRST_TEST_WEEK),
        index, target_cat, pop_amount, pop_occurrence,
    )
    occurrence, conditional = lightgbm.predict(X_cal)
    raw = occurrence * conditional
    bias_factor = float(np.clip(y_cal.sum() / max(raw.sum(), 1), 0.75, 1.35))

    models = {
        "amountOccurrence": export_booster(lightgbm.occurrence, "sigmoid"),
        "amountConditionalLog": export_booster(lightgbm.amount, "identity"),
        "safeQ75": export_booster(q75.model, "identity"),
    }
    fixtures = []
    for i in [0, len(X_cal) // 3, 2 * len(X_cal) // 3, len(X_cal) - 1]:
        row = {key: float(value) for key, value in X_cal.iloc[i].items()}
        p = evaluate(models["amountOccurrence"], row)
        log_amount = evaluate(models["amountConditionalLog"], row)
        fixtures.append({
            "features": row,
            "central": max(0.0, p * np.expm1(log_amount) * bias_factor),
            "safe": max(0.0, evaluate(models["safeQ75"], row)),
        })
    metadata = {
        "biasFactor": bias_factor,
        "populationAmount": {key: float(value) for key, value in pop_amount.items()},
        "populationOccurrence": {key: float(value) for key, value in pop_occurrence.items()},
    }
    return {"models": models, "metadata": metadata}, {"amount": fixtures}


def calibrator_coefficients(calibrator) -> dict:
    return {
        "coefficient": float(calibrator.model.coef_[0, 0]),
        "intercept": float(calibrator.model.intercept_[0]),
    }


def hazard_models() -> tuple[dict, dict]:
    hazard_generator.SEED = HAZARD_SEED
    amount_base.SEED = HAZARD_SEED + 10_000
    true_tx, calendar = hazard_generator.generate()
    observed = amount_base.add_observation_noise(true_tx)
    index = amount_base.make_index(observed, calendar)
    targets, _ = amount_base.true_targets(true_tx)
    pop_amount, pop_occurrence = hazard_experiment.population_stats(true_tx)
    first_events = hazard_experiment.first_event_lookup(true_tx)

    train_X, _, train_y = hazard_experiment.weekly_rows(
        hazard_experiment.TRAIN_PEOPLE, hazard_experiment.TRAIN_WEEKS,
        index, targets, pop_amount, pop_occurrence,
    )
    train_day_X, _, train_day_y = hazard_experiment.daily_rows(
        hazard_experiment.TRAIN_PEOPLE, hazard_experiment.TRAIN_WEEKS,
        index, first_events, pop_amount, pop_occurrence, calendar, training=True,
    )
    del train_X, train_y
    plain = hazard_experiment.HazardModel(HAZARD_SEED, calendar=False)
    with_calendar = hazard_experiment.HazardModel(HAZARD_SEED, calendar=True)
    plain.fit(train_day_X, train_day_y)
    with_calendar.fit(train_day_X, train_day_y)

    cal_X, cal_meta, cal_y = hazard_experiment.weekly_rows(
        hazard_experiment.CALIBRATION_PEOPLE, hazard_experiment.CALIBRATION_WEEKS,
        index, targets, pop_amount, pop_occurrence,
    )
    cal_day_X, cal_day_meta, _ = hazard_experiment.daily_rows(
        hazard_experiment.CALIBRATION_PEOPLE, hazard_experiment.CALIBRATION_WEEKS,
        index, first_events, pop_amount, pop_occurrence, calendar, training=False,
    )
    models = {
        "hazard": export_booster(plain.model, "sigmoid"),
        "hazardCalendar": export_booster(with_calendar.model, "sigmoid"),
    }
    calibrators = {}
    for name, model in [("hazard", plain), ("hazardCalendar", with_calendar)]:
        prediction = model.predict_week(cal_day_X, cal_day_meta).raw_probability.to_numpy(float)
        calibrator = hazard_experiment.ProbabilityCalibrator()
        calibrator.fit(prediction, cal_y)
        calibrators[name] = calibrator_coefficients(calibrator)

    fixtures = []
    grouped = cal_day_meta.groupby(["person", "week", "category"], sort=False).indices
    for key in list(grouped)[:3]:
        indices = grouped[key]
        rows = [
            {column: float(value) for column, value in cal_day_X.iloc[i].items()}
            for i in indices
        ]
        item = {"rows": rows}
        for name in ["hazard", "hazardCalendar"]:
            # HazardModel.predict_week와 동일하게 일별 확률을 먼저 자른다.
            # 골든 파일도 실제 Python 제품 경로를 기준으로 만들어야 Swift와 비교할 수 있다.
            hazards = np.clip(
                np.asarray([evaluate(models[name], row) for row in rows], float),
                0.001,
                0.999,
            )
            survival = np.r_[1.0, np.cumprod(1 - hazards[:-1])]
            mass = survival * hazards
            raw = float(1 - np.prod(1 - hazards))
            c = calibrators[name]
            logit = np.log(np.clip(raw, 0.001, 0.999) / (1 - np.clip(raw, 0.001, 0.999)))
            calibrated = float(1 / (1 + np.exp(-(c["intercept"] + c["coefficient"] * logit))))
            item[name] = {"probability": calibrated, "offset": int(np.argmax(mass))}
        fixtures.append(item)

    metadata = {
        "calibrators": calibrators,
        "populationAmount": {key: float(value) for key, value in pop_amount.items()},
        "populationOccurrence": {key: float(value) for key, value in pop_occurrence.items()},
    }
    return {"models": models, "metadata": metadata}, {"hazard": fixtures}


def main() -> None:
    amount, golden = amount_models()
    hazard, hazard_golden = hazard_models()
    payload = {
        "modelVersion": MODEL_VERSION,
        "featureVersion": FEATURE_VERSION,
        "categories": amount_base.CATEGORIES,
        "amount": amount,
        "hazard": hazard,
    }
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    payload["checksum"] = hashlib.sha256(encoded).hexdigest()
    APP_OUT.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    golden.update(hazard_golden)
    golden["modelVersion"] = MODEL_VERSION
    GOLDEN_OUT.write_text(json.dumps(golden, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{APP_OUT} ({APP_OUT.stat().st_size / 1_000_000:.1f} MB)")
    print(GOLDEN_OUT)


if __name__ == "__main__":
    main()
