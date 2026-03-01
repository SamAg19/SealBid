// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IPropertyNFT is IERC721 {
    function mint(address to, bytes32 metadataHash) external returns (uint256 tokenId);
    function tokenMetadataHash(uint256 tokenId) external view returns (bytes32);
}