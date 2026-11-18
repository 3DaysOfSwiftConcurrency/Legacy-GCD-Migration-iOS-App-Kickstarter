@testable import Kickstarter_iOS
import Combine

import XCTest

final class SortViewModelTests: XCTestCase {
  private let sortOptions = ConcreteSortOption.allCases
  private var viewModel: SortViewModel<ConcreteSortOption>!

  override func setUp() {
    super.setUp()

    self.viewModel = SortViewModel(
      sortOptions: self.sortOptions,
      selectedSortOption: ConcreteSortOption.sortOne
    )
  }

  func testSortOptions() throws {
    XCTAssertEqual(self.viewModel.sortOptions, self.sortOptions)
  }

  func testIsSortOptionSelectedReflectsTheInitialSelection() throws {
    XCTAssertTrue(self.viewModel.isSortOptionSelected(.sortOne))
    XCTAssertFalse(self.viewModel.isSortOptionSelected(.sortTwo))
  }

  func testSortOptionSelected() throws {
    var cancellables: [AnyCancellable] = []

    var optionSelected: ConcreteSortOption?
    let selectionReceived = expectation(description: "Waiting for a sort option selected")
    let selectionApplied = expectation(description: "Waiting for the selected option to update")
    self.viewModel.selectedSortOption.sink { option in
      optionSelected = option
      selectionReceived.fulfill()

      DispatchQueue.main.async {
        if self.viewModel.isSortOptionSelected(option) {
          selectionApplied.fulfill()
        }
      }
    }
    .store(in: &cancellables)

    self.viewModel.selectSortOption(.sortThree)
    waitForExpectations(timeout: 0.1)
    XCTAssertEqual(optionSelected, .sortThree)
    XCTAssertTrue(self.viewModel.isSortOptionSelected(.sortThree))
  }

  func testCloseTapped() throws {
    var cancellables: [AnyCancellable] = []

    var didCloseTapped = false
    let expectation = expectation(description: "Waiting for close to be tapped")
    self.viewModel.closeTapped.sink { _ in
      didCloseTapped = true
      expectation.fulfill()
    }
    .store(in: &cancellables)

    self.viewModel.close()
    waitForExpectations(timeout: 0.1)
    XCTAssertEqual(didCloseTapped, true)
  }
}
