// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721, ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * Free to use NFT marketplace allowing for English auctions and instant buys (like e-bay)
 * Supports ERC721 and variants as long as `safeTransferFrom(address,address,uint)` remains unaltered
 * Complies with ERC2981 royalties on tokens
 * Its minimalistic logic implies an off-chain store to use in combination with the UI for decent UX
 */
contract MarketPlace is Ownable, Multicall {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;
    // using EnumerableMap for EnumerableMap.UintToAddressMap;

    enum Status {
        OPEN,
        SOLD,
        CANCELLED
    }
    struct Listing {
        address creator;
        IERC721 contractAddress;
        uint256 tokenId;
        uint256 deadline;
        IERC20 wantAsset;
        uint256 instaBuyPrice;
        uint256 baseBid;
        uint256 bid;
        address bidder;
        Status status;
    }

    Counters.Counter public id;
    mapping(uint256 => Listing) public listings;
    mapping(IERC721 => mapping(uint256 => bool)) public isTokenListed;

    event New(uint256 id, address indexed src);
    event Bid(uint256 id, address indexed src, uint256 amt);
    event Buy(uint256 id, address indexed src);
    event Delist(uint256 id);

    /**
     * @notice Create a listing for a Maybe token.
     * @dev Requires prior approval for transfering token
     * @param listing - Listing containing all relevant data
     */
    function list(Listing memory listing) external {
        require(
            !isTokenListed[listing.contractAddress][listing.tokenId],
            "Item already listed"
        );
        isTokenListed[listing.contractAddress][listing.tokenId] = true;
        listing.contractAddress.safeTransferFrom(
            _msgSender(),
            address(this),
            listing.tokenId
        );
        listing.creator = _msgSender();
        listing.status = Status.OPEN;
        uint256 currentId = id.current();
        listings[currentId] = listing;
        id.increment();
        emit New(currentId, _msgSender());
    }

    /**
     * @notice Cancel a listing
     * @param listingId - id of the listing to cancel
     */
    function delist(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        require(listing.status == Status.OPEN, "Item not available");
        require(block.timestamp <= listing.deadline, "Listing expired");
        require(_msgSender() == listing.creator, "Not allowed");
        listing.status = Status.CANCELLED;
        listings[listingId] = listing;
        if (listing.bidder != address(0)) {
            listing.wantAsset.safeTransferFrom(
                address(this),
                listing.bidder,
                listing.bid
            );
        }
        listing.contractAddress.safeTransferFrom(
            address(this),
            _msgSender(),
            listing.tokenId
        );
        emit Delist(listingId);
    }

    /**
     * @notice Place bid on listing `listingId` of `bid`
     * @param listingId - id of the listing
     * @param bid - bid amount
     */
    function placeBid(uint256 listingId, uint256 bid) external {
        Listing memory listing = listings[listingId];
        require(listing.status == Status.OPEN, "Item not available");
        require(block.timestamp <= listing.deadline, "Listing expired");
        require(bid > listing.baseBid, "Bid too low");
        require(bid > listing.bid, "Bid too low");
        if (listing.bidder != address(0)) {
            listing.wantAsset.safeTransferFrom(
                address(this),
                listing.bidder,
                listing.bid
            );
        }
        listing.wantAsset.safeTransferFrom(_msgSender(), address(this), bid);
        listing.bid = bid;
        listing.bidder = _msgSender();
        emit Bid(listingId, _msgSender(), bid);
    }

    /**
     * @notice Claim listing `listingId`
     * @param listingId - id of the listing to claim
     */
    function claim(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        require(block.timestamp >= listing.deadline, "Listing not expired");
        require(_msgSender() == listing.bidder, "Not allowed");
        _sold(listingId, listing, listing.bid);
    }

    /**
     * @notice Intantly buy listing `listingId`
     * @param listingId - the listing to buy
     */
    function instaBuy(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        require(listing.status == Status.OPEN, "Item not available");
        require(block.timestamp <= listing.deadline, "Listing expired");
        require(listing.bid > listing.instaBuyPrice, "Not allowed");
        _sold(listingId, listing, listing.instaBuyPrice);
    }

    function _sold(
        uint256 listingId,
        Listing memory listing,
        uint256 saleAmount
    ) internal {
        if (
            IERC165(address(listing.contractAddress)).supportsInterface(
                type(IERC2981).interfaceId
            )
        ) {
            (address receiver, uint256 amt) = IERC2981(
                address(listing.contractAddress)
            ).royaltyInfo(listing.tokenId, saleAmount);
            listing.wantAsset.safeTransferFrom(address(this), receiver, amt);
            listing.wantAsset.safeTransferFrom(
                address(this),
                address(listing.creator),
                saleAmount - amt
            );
        } else {
            listing.wantAsset.safeTransferFrom(
                address(this),
                address(listing.creator),
                saleAmount
            );
        }
        listing.contractAddress.safeTransferFrom(
            address(this),
            _msgSender(),
            listing.tokenId
        );
        isTokenListed[listing.contractAddress][listing.tokenId] = false;
        listing.status = Status.SOLD;
        listings[listingId] = listing;
        emit Buy(listingId, _msgSender());
    }

    /**
     * @notice catch all function to execute things like skim tokens sent to this contracts or other unforseen actions
     * @dev can't execute any of the functions from this contract
     */
    function execute(
        address target,
        bytes calldata data,
        bool delegate
    ) external onlyOwner {
        require(target != address(this));
        if (delegate) {
            Address.functionDelegateCall(target, data);
        } else {
            Address.functionCall(target, data);
        }
    }
}
