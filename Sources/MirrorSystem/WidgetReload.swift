import WidgetKit

public enum WidgetReload {
    public static func request() { WidgetCenter.shared.reloadTimelines(ofKind: "mirror.review-today") }
}
