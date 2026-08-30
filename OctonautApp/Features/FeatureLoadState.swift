enum OctonautLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}
