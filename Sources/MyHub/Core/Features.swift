/// Features that are built but not switched on yet.
enum Features {
    /// Microsoft 365 / Teams calendar through Microsoft Graph. Off until
    /// MyHub has its own app registration (Application ID) to ship with —
    /// see README → Microsoft 365 / Teams calendar and docs/PLAN.md phase 12.
    static let microsoftCalendar = false
}
