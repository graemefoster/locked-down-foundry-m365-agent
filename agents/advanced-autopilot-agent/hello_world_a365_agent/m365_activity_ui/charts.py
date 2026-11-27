"""Pure dict builders for chart cards: Teams ``Chart.*`` Adaptive Card elements (card 1.5).

Chart elements are a Teams extension and M365 Copilot support is unknown, so every chart element
carries an Adaptive Card ``fallback``: a Container of ColumnSet/TextBlock bars showing the same data.
Hosts that do not know ``Chart.*`` render the fallback.

Vocabulary mirrors the AgentCraft web BarChart/StackedBarChart: the title should state metric,
period and scope ("Sessions per day, last 7 days, Contoso"); values are labelled.
Docs: https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/charts-in-adaptive-cards
"""
from __future__ import annotations

from typing import Any, Mapping, Sequence

from .cards import adaptive_card

DEFAULT_MAX_CATEGORIES = 8
OTHER_LABEL = "Other"
_BAR_WIDTH = 12  # block characters for the longest fallback bar


def _num(v: Any) -> str:
    f = float(v)
    return f"{int(f):,}" if f == int(f) else f"{f:,.1f}"


def _title_block(title: str) -> dict[str, Any]:
    return {"type": "TextBlock", "text": title, "weight": "Bolder", "wrap": True}


def _no_data_card(title: str) -> dict[str, Any]:
    return adaptive_card([
        _title_block(title),
        {"type": "TextBlock", "text": "No data", "isSubtle": True, "wrap": True},
    ])


def _bar_text(value: float, peak: float) -> str:
    if peak <= 0 or value <= 0:
        return ""
    return "█" * max(1, round(_BAR_WIDTH * value / peak))


def _values_block(pairs: Sequence[tuple[str, str]]) -> dict[str, Any]:
    """Compact values line ("Urgent 3 · Newsletter 2") under every chart, so values stay readable
    even where the chart's own title/labels do not render."""
    return {"type": "TextBlock", "text": " · ".join(k + " " + v for k, v in pairs),
            "wrap": True, "size": "Small", "isSubtle": True, "spacing": "Small"}


def _chart_card(title: str, chart: dict[str, Any], values: Sequence[tuple[str, str]]) -> dict[str, Any]:
    """Card body: title TextBlock, the chart element, values TextBlock (all host-independent text)."""
    return adaptive_card([_title_block(title), chart, _values_block(values)])


def _fallback_rows(title: str, rows: Sequence[tuple[str, float, str]]) -> dict[str, Any]:
    """Container of one ``label | █ bar | value`` ColumnSet per row (label, magnitude, value text).
    No title inside: the card's TextBlock above the chart already carries it."""
    peak = max((r[1] for r in rows), default=0)
    items: list[dict[str, Any]] = []
    for label, magnitude, text in rows:
        items.append({"type": "ColumnSet", "spacing": "Small", "columns": [
            {"type": "Column", "width": 3, "items": [
                {"type": "TextBlock", "text": label, "wrap": True, "size": "Small"}]},
            {"type": "Column", "width": 4, "items": [
                {"type": "TextBlock", "text": _bar_text(magnitude, peak), "color": "Accent", "size": "Small", "wrap": False}]},
            {"type": "Column", "width": 3, "items": [
                {"type": "TextBlock", "text": text, "size": "Small", "weight": "Bolder", "wrap": True}]},
        ]})
    return {"type": "Container", "items": items}


def _top_n(pairs: list[tuple[str, float]], n: int) -> list[tuple[str, float]]:
    """Keep the n largest, fold the rest into one trailing "Other" (original order kept for the top n)."""
    if len(pairs) <= n:
        return pairs
    keep = sorted(range(len(pairs)), key=lambda i: -pairs[i][1])[:n]
    kept = [pairs[i] for i in sorted(keep)]
    rest = sum(v for i, (_, v) in enumerate(pairs) if i not in set(keep))
    return kept + [(OTHER_LABEL, rest)]


def _is_multi(series: Sequence[Mapping[str, Any]]) -> bool:
    return any("values" in s for s in series)


def bar_chart(title: str, series: Sequence[Mapping[str, Any]], *, stacked: bool = False,
              horizontal: bool = False, max_categories: int = DEFAULT_MAX_CATEGORIES,
              x_title: str | None = None, y_title: str | None = None) -> dict[str, Any]:
    """A bar chart card. ``series`` is either single-series ``[{"label", "value"}, ...]`` or
    multi-series ``[{"name", "values": {label: value}}, ...]`` (grouped, or ``stacked=True``).

    Elements: single → ``Chart.VerticalBar`` / ``Chart.HorizontalBar`` (``horizontal=True``);
    multi → ``Chart.VerticalBar.Grouped`` (``stacked`` sets its ``stacked`` flag); multi +
    ``stacked`` + ``horizontal`` → ``Chart.HorizontalBar.Stacked``. Horizontal non-stacked multi is
    not a Teams chart and raises ``ValueError``.
    More than ``max_categories`` categories keep the largest (by total) and fold the rest into "Other".
    Empty series (or all-empty values) → a "No data" card."""
    multi = _is_multi(series)
    if multi:
        names = [str(s.get("name", "")) for s in series]
        cats: dict[str, dict[str, float]] = {}
        for s in series:
            for label, v in dict(s.get("values") or {}).items():
                cats.setdefault(str(label), {})[str(s.get("name", ""))] = float(v)
    else:
        cats = {}
        for s in series:
            cats[str(s["label"])] = {"": cats.get(str(s["label"]), {}).get("", 0.0) + float(s["value"])}
        names = [""]
    if not cats:
        return _no_data_card(title)

    if len(cats) > max_categories:
        top = sorted(cats, key=lambda c: -sum(cats[c].values()))[:max_categories]
        folded = {c: v for c, v in cats.items() if c in top}
        other: dict[str, float] = {}
        for c, v in cats.items():
            if c not in top:
                for k, x in v.items():
                    other[k] = other.get(k, 0.0) + x
        folded[OTHER_LABEL] = other
        cats = folded

    axes: dict[str, Any] = {}
    if x_title:
        axes["xAxisTitle"] = x_title
    if y_title:
        axes["yAxisTitle"] = y_title

    if not multi:
        data = [{"x": c, "y": v[""]} for c, v in cats.items()]
        chart: dict[str, Any] = {"type": "Chart.HorizontalBar" if horizontal else "Chart.VerticalBar",
                                 "title": title, **axes, "colorSet": "categorical", "data": data}
        if not horizontal:
            chart["showBarValues"] = True
        rows = [(c, v[""], _num(v[""])) for c, v in cats.items()]
    else:
        if horizontal and not stacked:
            raise ValueError("horizontal multi-series bars are only available stacked")
        if horizontal:
            data = [{"title": n, "data": [{"legend": c, "value": cats[c].get(n, 0.0)} for c in cats]}
                    for n in names]
            chart = {"type": "Chart.HorizontalBar.Stacked", "title": title, "colorSet": "categorical", "data": data}
        else:
            data = [{"legend": n, "values": [{"x": c, "y": cats[c].get(n, 0.0)} for c in cats]} for n in names]
            chart = {"type": "Chart.VerticalBar.Grouped", "title": title, **axes, "colorSet": "categorical",
                     "showBarValues": True, "data": data}
            if stacked:
                chart["stacked"] = True
        rows = [(c, sum(v.values()), f"{_num(sum(v.values()))}\n" + ", ".join(
                    f"{n} {_num(v.get(n, 0))}" for n in names)) for c, v in cats.items()]
    chart["fallback"] = _fallback_rows(title, rows)
    return _chart_card(title, chart, [(c, _num(sum(v.values()))) for c, v in cats.items()])


def donut_chart(title: str, slices: Sequence[Mapping[str, Any]], *,
                max_categories: int = DEFAULT_MAX_CATEGORIES) -> dict[str, Any]:
    """A donut chart card from ``[{"label", "value"}, ...]``. Non-positive slices are dropped; more
    than ``max_categories`` keep the largest and fold the rest into "Other"; nothing left → "No data"."""
    pairs = [(str(s["label"]), float(s["value"])) for s in slices if float(s["value"]) > 0]
    if not pairs:
        return _no_data_card(title)
    pairs = _top_n(pairs, max_categories)
    total = sum(v for _, v in pairs)
    chart = {"type": "Chart.Donut", "title": title, "colorSet": "categorical",
             "data": [{"legend": c, "value": v} for c, v in pairs]}
    chart["fallback"] = _fallback_rows(
        title, [(c, v, f"{_num(v)} · {100 * v / total:.0f}%") for c, v in pairs])
    return _chart_card(title, chart, [(c, _num(v)) for c, v in pairs])


def pie_chart(title: str, slices: Sequence[Mapping[str, Any]], *,
              max_categories: int = DEFAULT_MAX_CATEGORIES) -> dict[str, Any]:
    """A pie chart card (``Chart.Pie``); same input, folding and "No data" rules as ``donut_chart``."""
    card = donut_chart(title, slices, max_categories=max_categories)
    for block in card["body"]:
        if block.get("type") == "Chart.Donut":
            block["type"] = "Chart.Pie"
    return card


def horizontal_bar_chart(title: str, series: Sequence[Mapping[str, Any]], *, stacked: bool = False,
                         max_categories: int = DEFAULT_MAX_CATEGORIES,
                         x_title: str | None = None, y_title: str | None = None) -> dict[str, Any]:
    """``bar_chart(..., horizontal=True)``: ``Chart.HorizontalBar`` for single series, and
    ``Chart.HorizontalBar.Stacked`` for multi-series (which is always stacked)."""
    return bar_chart(title, series, stacked=stacked or _is_multi(series), horizontal=True,
                     max_categories=max_categories, x_title=x_title, y_title=y_title)


def line_chart(title: str, series: Sequence[Mapping[str, Any]], *,
               x_title: str | None = None, y_title: str | None = None) -> dict[str, Any]:
    """A line chart card (``Chart.Line``). ``series`` is single-series ``[{"label", "value"}, ...]``
    (x labels in the given order) or multi-series ``[{"name", "values": {x: value}}, ...]``; x order is
    first-seen and never folded (a line is ordered). Empty series → a "No data" card."""
    if _is_multi(series):
        named = [(str(s.get("name", "")), {str(k): float(v) for k, v in dict(s.get("values") or {}).items()})
                 for s in series]
    else:
        pts: dict[str, float] = {}
        for s in series:
            pts[str(s["label"])] = pts.get(str(s["label"]), 0.0) + float(s["value"])
        named = [("", pts)]
    xs: list[str] = []
    for _, vals in named:
        xs += [x for x in vals if x not in xs]
    if not xs:
        return _no_data_card(title)
    data = [{"legend": n or title, "values": [{"x": x, "y": vals[x]} for x in xs if x in vals]}
            for n, vals in named if vals]
    chart: dict[str, Any] = {"type": "Chart.Line", "title": title, "colorSet": "categorical", "data": data}
    if x_title:
        chart["xAxisTitle"] = x_title
    if y_title:
        chart["yAxisTitle"] = y_title
    rows = []
    for x in xs:
        got = [(n, vals[x]) for n, vals in named if x in vals]
        text = _num(got[0][1]) if len(got) == 1 and not got[0][0] else ", ".join(f"{n} {_num(v)}" for n, v in got)
        rows.append((x, sum(v for _, v in got), text))
    chart["fallback"] = _fallback_rows(title, rows)
    return _chart_card(title, chart, [(r[0], r[2]) for r in rows])


def gauge_chart(title: str, value: float | None, *, target: float | None = None, min_value: float = 0,
                max_value: float = 100, segments: Sequence[Mapping[str, Any]] | None = None,
                sub_label: str | None = None, unit: str = "") -> dict[str, Any]:
    """A gauge card (``Chart.Gauge``) for one KPI. ``value`` is clamped to ``[min_value, max_value]``;
    ``None`` → "No data" card. ``segments`` is optional ``[{"legend", "size", "color"?}, ...]`` (e.g.
    low/medium/high bands); without it the gauge shows Achieved vs Remaining, and ``target`` (if given)
    is stated in the sub-label ("Target 80%") and values line, with the achieved band ``good`` once met
    and ``warning`` before. ``unit`` is appended to displayed numbers ("%", " ms")."""
    if value is None:
        return _no_data_card(title)
    lo, hi = float(min_value), float(max_value)
    if hi <= lo:
        raise ValueError("max_value must be greater than min_value")
    v = min(max(float(value), lo), hi)
    shown = _num(value) + unit
    if segments:
        segs = [{"legend": str(s["legend"]), "size": float(s["size"]), "value": float(s["size"]),
                 **({"color": s["color"]} if s.get("color") else {})} for s in segments]
    else:
        met = target is not None and v >= float(target)
        achieved: dict[str, Any] = {"legend": "Achieved", "size": v - lo, "value": v - lo}
        if target is not None:
            achieved["color"] = "good" if met else "warning"
        segs = [achieved, {"legend": "Remaining", "size": hi - v, "value": hi - v, "color": "neutral"}]
    pairs = [("Value", shown)]
    chart: dict[str, Any] = {"type": "Chart.Gauge", "title": title, "value": v, "min": lo, "max": hi,
                             "valueFormat": "Fraction", "showMinMax": True, "segments": segs}
    if target is not None:
        pairs.append(("Target", _num(target) + unit))
        sub_label = sub_label or f"Target {_num(target)}{unit}"
    if sub_label:
        chart["subLabel"] = sub_label
    span = hi - lo
    rows = [("Value", v - lo, f"{shown} · {100 * (v - lo) / span:.0f}% of range")]
    if target is not None:
        rows.append(("Target", float(target) - lo, _num(target) + unit))
    chart["fallback"] = _fallback_rows(title, [(a, max(m, 0.0), t) for a, m, t in rows])
    return _chart_card(title, chart, pairs)
