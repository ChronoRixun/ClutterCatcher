import Foundation

/// The canonical starter catalog (D12). UUIDs are fixed at compile time so
/// Owen's first launch always produces the same rows — and, come M2+, the same
/// CKRecord recordNames. Participants never seed; they bootstrap from the
/// shared zone (M3).
///
/// The room/category sets are a starting point, freely editable in-app.
/// See "Questions for Owen" in OPEN_ITEMS.md.
enum SeedData {
    struct SeedRoom {
        let id: String
        let name: String
        let icon: String
    }

    struct SeedCategory {
        let id: String
        let name: String
        let colorToken: String
    }

    static let rooms: [SeedRoom] = [
        SeedRoom(id: "24402771-2003-49A1-B676-A16C284102B3", name: "Kitchen", icon: "fork.knife"),
        SeedRoom(id: "58BBB191-042C-499D-900E-7D71B17176E2", name: "Living Room", icon: "sofa"),
        SeedRoom(id: "E1FE8661-F994-42F7-886F-4A9616DCC78E", name: "Office", icon: "lamp.desk"),
        SeedRoom(id: "5722A213-22B8-4293-BE7F-4987C2BAC4B7", name: "Primary Bedroom", icon: "bed.double"),
        SeedRoom(id: "FCB88EE7-64D0-4104-B4B6-A78F3DEE4361", name: "Andrew's Room", icon: "gamecontroller"),
        SeedRoom(id: "14EB0182-8BDD-4D8C-937D-17FBD825AFD1", name: "Michael's Room", icon: "books.vertical"),
        SeedRoom(id: "D39729C3-6A8A-41E5-92FC-36D97DACB7A8", name: "Garage", icon: "car"),
        SeedRoom(id: "42047207-1C4B-49CB-99EA-76117B458C9E", name: "Basement", icon: "stairs"),
    ]

    static let categories: [SeedCategory] = [
        SeedCategory(id: "BD0045CA-8656-4D9B-B551-98A5A6B0705E", name: "Seasonal & Holiday", colorToken: "red"),
        SeedCategory(id: "D94FBEE2-9AC2-4AE2-ACBA-BD2C444DAD1E", name: "Tools & Hardware", colorToken: "orange"),
        SeedCategory(id: "926ED3C5-2367-4FCB-9A5D-E084CC717848", name: "Electronics & Cables", colorToken: "blue"),
        SeedCategory(id: "8FEA0E5F-A28A-45DA-9094-E906283FA767", name: "Camping & Outdoor", colorToken: "green"),
        SeedCategory(id: "3815A45E-2B92-43BB-943D-1E4EA6AB4B20", name: "Sports & Recreation", colorToken: "teal"),
        SeedCategory(id: "22DF3D2B-0A93-4E44-8AD3-2B59D2EDE26F", name: "Toys & Games", colorToken: "purple"),
        SeedCategory(id: "DCD09B87-A116-4399-A872-31278115001E", name: "Clothing & Textiles", colorToken: "pink"),
        SeedCategory(id: "3C032A99-A17A-4F80-81EE-237D488FF9DE", name: "Books & Media", colorToken: "indigo"),
        SeedCategory(id: "FB07D449-4986-4D2D-AF85-AAB3BEB7C05B", name: "Documents & Paperwork", colorToken: "brown"),
        SeedCategory(id: "749DDA04-880D-4039-8EE1-957EB49AEB71", name: "Crafts & Hobbies", colorToken: "mint"),
        SeedCategory(id: "380F1662-86CB-49EF-9E7D-F53500DE59DC", name: "Keepsakes & Memorabilia", colorToken: "gray"),
    ]
}
