//SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IERC721NFT.sol";
import "./interfaces/IMarketplace.sol";

contract Marketplace is ReentrancyGuard, Ownable, IERC721Receiver {
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIds;
    Counters.Counter private _totalAmount;
    Counters.Counter private _itemsSold;

    IERC721 private NFT;
    IERC20 private ERC20Token;

    uint256 private _mintPrice;
    uint256 private _auctionDuration;
    uint256 private _auctionMinimalBidAmount;

    constructor(
        uint256 newPrice,
        uint256 newAuctionDuration,
        uint256 newAuctionMinimalBidAmount
    ) {
        setMintPrice(newPrice);
        setAuctionDuration(newAuctionDuration);
        setAuctionMinimalBidAmount(newAuctionMinimalBidAmount);
    }

    mapping(uint256 => TokenStatus) private _idToItemStatus;
    mapping(uint256 => SaleOrder) private _idToOrder;
    mapping(uint256 => AuctionOrder) private _idToAuctionOrder;

    modifier isActive(uint256 tokenId) {
        require(
            _idToItemStatus[tokenId] == TokenStatus.ACTIVE,
            "Marketplace: This NFT has already been put up for sale or auction!"
        );
        _;
    }

    modifier auctionIsActive(uint256 tokenId) {
        require(
            _idToAuctionOrder[tokenId].status == AuctionStatus.ACTIVE,
            "Marketplace: Auction already ended!"
        );
        _;
    }

    /**
     *@notice Create item for sale
     *@param tokenURI place where the NFT is located
     *@param owner address where the NFT was create
     **/
    function createItem(string memory tokenURI, address owner) external {
        ERC20Token.transferFrom(msg.sender, address(this), _mintPrice);

        _totalAmount.increment();
        _tokenIds.increment();

        uint256 tokenId = _tokenIds.current();

        NFT.mint(owner, tokenId, tokenURI);

        _idToItemStatus[tokenId] = TokenStatus.ACTIVE;
        emit MarketItemCreated(tokenId, owner, block.timestamp);
    }

    /**
     *@notice Give NFT to auction
     *@param tokenId identifier NFT token
     *@param price for sale at auction
     **/
    function listItem(uint256 tokenId, uint256 price)
        external
        isActive(tokenId)
    {
        address owner = NFT.ownerOf(tokenId);
        NFT.safeTransferFrom(owner, address(this), tokenId);

        _idToItemStatus[tokenId] = TokenStatus.ONSELL;

        _idToOrder[tokenId] = SaleOrder(
            msg.sender,
            owner,
            price,
            SaleStatus.ACTIVE
        );

        emit ListedForSale(tokenId, price, block.timestamp, owner, msg.sender);
    }

    /**
     *@notice Buy NFT
     *@param tokenId identifier NFT token
     **/
    function buyItem(uint256 tokenId) external nonReentrant {
        SaleOrder storage order = _idToOrder[tokenId];
        require(
            order.status == SaleStatus.ACTIVE,
            "Marketplace: The token isn't on sale"
        );

        order.status = SaleStatus.SOLD;
        ERC20Token.transferFrom(msg.sender, order.seller, order.price);

        NFT.safeTransferFrom(address(this), msg.sender, tokenId);
        _idToItemStatus[tokenId] = TokenStatus.ACTIVE;

        _itemsSold.increment();

        emit Sold(
            tokenId,
            order.price,
            block.timestamp,
            order.seller,
            msg.sender
        );
    }

    /**
     *@notice Close the market and send the token to the buyer
     *@param tokenId identifier NFT token
     **/
    function cancel(uint256 tokenId) external nonReentrant {
        SaleOrder storage order = _idToOrder[tokenId];

        require(
            msg.sender == order.owner || msg.sender == order.seller,
            "Marketplace: You don't have the authority to cancel the sale of this token!"
        );
        require(
            _idToOrder[tokenId].status == SaleStatus.ACTIVE,
            "Marketplace: The token wasn't on sale"
        );

        NFT.safeTransferFrom(address(this), order.owner, tokenId);

        order.status = SaleStatus.CANCELLED;
        _idToItemStatus[tokenId] = TokenStatus.ACTIVE;

        emit EventCanceled(tokenId, msg.sender);
    }

    /**
     *@notice Create item for sale
     *@param tokenId place where the NFT is located
     *@param price address where the NFT was create
     **/
    function listItemOnAuction(uint256 tokenId, uint256 minPrice)
        external
        isActive(tokenId)
    {
        address owner = NFT.ownerOf(tokenId);
        NFT.safeTransferFrom(owner, address(this), tokenId);

        _idToItemStatus[tokenId] = TokenStatus.ONAUCTION;

        _idToAuctionOrder[tokenId] = AuctionOrder(
            minPrice,
            block.timestamp,
            0,
            0,
            owner,
            msg.sender,
            address(0),
            AuctionStatus.ACTIVE
        );

        emit StartAuction(tokenId, minPrice, msg.sender, block.timestamp);
    }

    /**
     *@notice Make bid for select item
     *@param tokenId identifier NFT
     *@param price bid
     **/
    function makeBid(uint256 tokenId, uint256 price)
        external
        auctionIsActive(tokenId)
    {
        AuctionOrder storage order = _idToAuctionOrder[tokenId];

        require(
            price > order.currentPrice && price >= order.startPrice,
            "Marketplace: Your bid less or equal to current bid!"
        );

        if (order.currentPrice != 0)
            ERC20Token.transfer(order.lastBidder, order.currentPrice);

        order.currentPrice = price;
        order.lastBidder = msg.sender;
        order.bidAmount += 1;

        ERC20Token.transferFrom(msg.sender, address(this), price);

        emit BidIsMade(tokenId, price, order.bidAmount, order.lastBidder);
    }

    /**
     *@notice Finish auction and transfer token to winner or last bidder
     *@param tokenId identifier NFT
     **/
    function finishAuction(uint256 tokenId)
        external
        auctionIsActive(tokenId)
        nonReentrant
    {
        AuctionOrder storage order = _idToAuctionOrder[tokenId];

        require(
            order.startTime + _auctionDuration < block.timestamp,
            "Marketplace: Auction duration not complited!"
        );

        if (order.bidAmount < _auctionMinimalBidAmount) {
            _cancelAuction(tokenId);
            emit NegativeEndAuction(tokenId, order.bidAmount, block.timestamp);
            return;
        }

        NFT.safeTransferFrom(address(this), order.lastBidder, tokenId);
        ERC20Token.transfer(order.seller, order.currentPrice);

        order.status = AuctionStatus.SUCCESSFUL_ENDED;
        _idToItemStatus[tokenId] = TokenStatus.ACTIVE;

        _itemsSold.increment();
        emit PositiveEndAuction(
            tokenId,
            order.currentPrice,
            order.bidAmount,
            block.timestamp,
            order.seller,
            order.lastBidder
        );
    }

    /**
     *@notice Cancel auction
     *@param tokenId identifier NFT
     **/
    function cancelAuction(uint256 tokenId) external nonReentrant {
        // In the future, it's best to use Error()
        require(
            msg.sender == _idToAuctionOrder[tokenId].owner ||
                msg.sender == _idToAuctionOrder[tokenId].seller,
            "Marketplace: You don't have the authority to cancel the sale of this token!"
        );
        require(
            _idToAuctionOrder[tokenId].bidAmount == 0,
            "Marketplace: You can't cancel the auction which already has a bidder!"
        );
        _cancelAuction(tokenId);
        emit EventCanceled(tokenId, _idToAuctionOrder[tokenId].seller);
    }

    function _cancelAuction(uint256 tokenId) private {
        _idToAuctionOrder[tokenId].status = AuctionStatus.UNSUCCESSFULLY_ENDED;

        NFT.safeTransferFrom(
            address(this),
            _idToAuctionOrder[tokenId].owner,
            tokenId
        );
        _idToItemStatus[tokenId] = TokenStatus.ACTIVE;

        if (_idToAuctionOrder[tokenId].bidAmount != 0) {
            ERC20Token.transfer(
                _idToAuctionOrder[tokenId].lastBidder,
                _idToAuctionOrder[tokenId].currentPrice
            );
        }
    }

    /**
     *@notice Burn NFT
     *@param tokenId identifier NFT
     **/
    function burn(uint256 tokenId) external isActive(tokenId) {
        address owner = NFT.ownerOf(tokenId);
        require(
            owner == msg.sender,
            "Marketplace: Only owner can burn a token!"
        );

        NFT.burn(tokenId);

        _totalAmount.decrement();
        _idToItemStatus[tokenId] = TokenStatus.BURNED;
        emit Burned(tokenId, msg.sender, block.timestamp);
    }

    /**
     *@notice Withdraw ERC20 from a marketplace contract
     *@param receiver beneficiary's address
     *@param amount amount of funds sent
     **/
    function withdrawTokens(address receiver, uint256 amount)
        external
        onlyOwner
    {
        ERC20Token.transfer(receiver, amount);
    }

    /**
     *@notice Set new NFT address
     *@param newNFTAddress new NFT address for exchange
     **/
    function setNFTAddress(address newNFTAddress) external onlyOwner {
        emit NFTAddressChanged(address(NFT), newNFTAddress);
        NFT = IERC721(newNFTAddress);
    }

    /**
     *@notice Set new ERC20 address
     *@param newToken new ERC20 address for exchange
     **/
    function setERC20Token(address newToken) external onlyOwner {
        emit ERC20AddressChanged(address(ERC20Token), newToken);
        ERC20Token = IERC20(newToken);
    }

    /**
     *@notice Different get- or set- function
     **/
    function getNFT() external view returns (address) {
        return address(NFT);
    }

    function getTokenStatus(uint256 tokenId)
        external
        view
        returns (TokenStatus)
    {
        return _idToItemStatus[tokenId];
    }

    function getSaleOrder(uint256 tokenId)
        external
        view
        returns (SaleOrder memory)
    {
        return _idToOrder[tokenId];
    }

    function getAuctionOrder(uint256 tokenId)
        external
        view
        returns (AuctionOrder memory)
    {
        return _idToAuctionOrder[tokenId];
    }

    function getMintPrice() external view returns (uint256) {
        return _mintPrice;
    }

    function getAuctionMinimalBidAmount() external view returns (uint256) {
        return _auctionMinimalBidAmount;
    }

    function getAuctionDuration() external view returns (uint256) {
        return _auctionDuration;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        emit NFTReceived(operator, from, tokenId, data);
        return IERC721Receiver.onERC721Received.selector;
    }

    function setAuctionMinimalBidAmount(uint256 newAuctionMinimalBidAmount)
        public
        onlyOwner
    {
        _auctionMinimalBidAmount = newAuctionMinimalBidAmount;
        emit AuctionMinimalBidAmountUpgraded(
            newAuctionMinimalBidAmount,
            block.timestamp
        );
    }

    function setMintPrice(uint256 _newPrice) public onlyOwner {
        uint256 newPrice = _newPrice;
        emit MintPriceUpgraded(_mintPrice, newPrice, block.timestamp);
        _mintPrice = newPrice;
    }

    function setAuctionDuration(uint256 newAuctionDuration) public onlyOwner {
        _auctionDuration = newAuctionDuration;
        emit AuctionDurationUpgraded(newAuctionDuration, block.timestamp);
    }
}