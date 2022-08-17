// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721, ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MarketPlace is Context {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    enum Status {
        OPEN,
        SOLD,
        CANCELLED
    }
    struct Listing {
        address creator;
        uint256 tokenId;
        uint256 deadline;
        IERC20 wantAsset;
        uint256 instaBuyPrice;
        uint256 baseBid;
        uint256 bid;
        address bidder;
        Status status;
    }

    IERC721 public immutable MAYBE;
    Counters.Counter public id;
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => bool) public isTokenBeingSold;

    event New(uint256 id, address indexed src);
    event Bid(uint256 id, address indexed src, uint256 amt);
    event Buy(uint256 id, address indexed src);
    event Delist(uint256 id);

    constructor(address maybe_) {
        MAYBE = IERC721(maybe_);
    }

    function list(Listing memory listing) external {
        require(!isTokenBeingSold[listing.tokenId], "Item already listed");
        isTokenBeingSold[listing.tokenId] = true;
        MAYBE.safeTransferFrom(_msgSender(), address(this), listing.tokenId);
        listing.creator = _msgSender();
        listing.status = Status.OPEN;
        uint256 currentId = id.current();
        listings[currentId] = listing;
        id.increment();
        emit New(currentId, _msgSender());
    }

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
        emit Delist(listingId);
    }

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

    function claim(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        require(block.timestamp >= listing.deadline, "Listing not expired");
        require(_msgSender() == listing.bidder, "Not allowed");
        (address receiver, uint256 amt) = IERC2981(address(MAYBE)).royaltyInfo(
            listing.tokenId,
            listing.bid
        );
        listing.wantAsset.safeTransferFrom(address(this), receiver, amt);
        listing.wantAsset.safeTransferFrom(
            address(this),
            address(listing.creator),
            listing.bid - amt
        );
        MAYBE.safeTransferFrom(address(this), _msgSender(), listing.tokenId);
        _sold(listingId, listing);
    }

    function instaBuy(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        require(listing.status == Status.OPEN, "Item not available");
        require(block.timestamp <= listing.deadline, "Listing expired");
        require(listing.bid > listing.instaBuyPrice, "Not allowed");
        (address receiver, uint256 amt) = IERC2981(address(MAYBE)).royaltyInfo(
            listing.tokenId,
            listing.instaBuyPrice
        );
        listing.wantAsset.safeTransferFrom(_msgSender(), receiver, amt);
        listing.wantAsset.safeTransferFrom(
            _msgSender(),
            address(listing.creator),
            listing.instaBuyPrice - amt
        );
        MAYBE.safeTransferFrom(address(this), _msgSender(), listing.tokenId);
        _sold(listingId, listing);
    }

    function _sold(uint256 listingId, Listing memory listing) internal {
        isTokenBeingSold[listing.tokenId] = false;
        listing.status = Status.SOLD;
        listings[listingId] = listing;
        emit Buy(listingId, _msgSender());
    }
}
