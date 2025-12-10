Prefferd Changes
==================
## Preferred Changes List (Contract Level)
- [ ] Adding support for campaign task
    - [ ] Humanity verification
    - [ ] Payment verification
    - [ ] Keep modularity in the contract to add more tasks in the future
- [ ] Refactor complete reward set & distribution logic
    - [ ] Make it more gas efficient
    - [ ] Make it more modular to add new reward types in the future
- [ ] Improve NFT support
    - [ ] Add support for multiple NFT standards (ERC721, ERC1155)
    - [ ] Make NFT reward distribution more efficient and easy to manage
- [ ] Bulk operations
    - [x] Add support to sign multiple transactions in a single call
    - [x] User should be able to edit and cancel the campaign until it is live
- [ ] test coverage
    - [ ] Increase test coverage to at least 90%
    - [ ] Add more edge case tests
## Preferred Changes List (Frontend Level)
-campaign creation flow
    -campaign realated transactions should be handled in the very end of the flow when user is going to make the campaign live
        -make sure user/host has to sign minimum number of transactions(bundle transactions where possible)

    -add more customization options for campaign creators
        -custom reward types
        -custom task types
        -custom form fields to collect more data from users
-improve user dashboard

