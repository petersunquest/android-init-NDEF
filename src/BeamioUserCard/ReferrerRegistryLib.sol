// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReferrerStorage.sol";

/// @dev Maintains referrer/referee indexes for paginated on-chain queries.
library ReferrerRegistryLib {
    uint256 internal constant MAX_PAGE_SIZE = 100;

    function onRegisterReferee(ReferrerStorage.Layout storage r, address refereeAA) internal {
        if (r.registeredRefereeIndexPlusOne[refereeAA] != 0) return;
        r.registeredRefereeList.push(refereeAA);
        r.registeredRefereeIndexPlusOne[refereeAA] = r.registeredRefereeList.length;
    }

    function onUnregisterReferee(ReferrerStorage.Layout storage r, address refereeAA) external {
        _unlinkRefereeFromReferrer(r, refereeAA);
        delete r.referrerOfReferee[refereeAA];
        _removeFromAddressList(
            r.registeredRefereeList,
            refereeAA,
            r.registeredRefereeIndexPlusOne
        );
    }

    function onSetRefereeReferrer(ReferrerStorage.Layout storage r, address refereeAA, address referrerAA) internal {
        address oldReferrer = r.referrerOfReferee[refereeAA];
        if (oldReferrer != address(0) && oldReferrer != referrerAA) {
            _removeRefereeFromReferrerList(r, oldReferrer, refereeAA);
        }
        r.referrerOfReferee[refereeAA] = referrerAA;
        _addRefereeToReferrerList(r, referrerAA, refereeAA);
    }

    function onClearRefereeReferrer(ReferrerStorage.Layout storage r, address refereeAA) external {
        _unlinkRefereeFromReferrer(r, refereeAA);
        delete r.referrerOfReferee[refereeAA];
    }

    function referrerTotalCount(ReferrerStorage.Layout storage r) external view returns (uint256) {
        return r.referrerAccountList.length;
    }

    function refereeCountByReferrer(ReferrerStorage.Layout storage r, address referrerAA) external view returns (uint256) {
        return r.refereesOfReferrer[referrerAA].length;
    }

    function registeredRefereeTotalCount(ReferrerStorage.Layout storage r) external view returns (uint256) {
        return r.registeredRefereeList.length;
    }

    function getReferrersPage(ReferrerStorage.Layout storage r, uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referrers, uint256 total, uint256 nextOffset)
    {
        return _pageAddressArray(r.referrerAccountList, offset, pageSize);
    }

    function getRefereesByReferrerPage(
        ReferrerStorage.Layout storage r,
        address referrerAA,
        uint256 offset,
        uint256 pageSize
    ) external view returns (address[] memory referees, uint256 total, uint256 nextOffset) {
        return _pageAddressArray(r.refereesOfReferrer[referrerAA], offset, pageSize);
    }

    function getRegisteredRefereesPage(ReferrerStorage.Layout storage r, uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256 total, uint256 nextOffset)
    {
        return _pageAddressArray(r.registeredRefereeList, offset, pageSize);
    }

    function _unlinkRefereeFromReferrer(ReferrerStorage.Layout storage r, address refereeAA) internal {
        address oldReferrer = r.referrerOfReferee[refereeAA];
        if (oldReferrer == address(0)) return;
        _removeRefereeFromReferrerList(r, oldReferrer, refereeAA);
    }

    function _addRefereeToReferrerList(ReferrerStorage.Layout storage r, address referrerAA, address refereeAA) internal {
        if (r.refereeIndexInReferrerPlusOne[referrerAA][refereeAA] != 0) return;
        r.refereesOfReferrer[referrerAA].push(refereeAA);
        r.refereeIndexInReferrerPlusOne[referrerAA][refereeAA] = r.refereesOfReferrer[referrerAA].length;
        _appendReferrerAccount(r, referrerAA);
    }

    function _removeRefereeFromReferrerList(ReferrerStorage.Layout storage r, address referrerAA, address refereeAA)
        internal
    {
        uint256 idxPlusOne = r.refereeIndexInReferrerPlusOne[referrerAA][refereeAA];
        if (idxPlusOne == 0) return;
        _removeFromAddressListAtIndex(r.refereesOfReferrer[referrerAA], idxPlusOne - 1);
        delete r.refereeIndexInReferrerPlusOne[referrerAA][refereeAA];
        _reindexReferrerReferees(r, referrerAA);
        if (r.refereesOfReferrer[referrerAA].length == 0) {
            _removeReferrerAccount(r, referrerAA);
        }
    }

    function _reindexReferrerReferees(ReferrerStorage.Layout storage r, address referrerAA) internal {
        address[] storage list = r.refereesOfReferrer[referrerAA];
        for (uint256 i = 0; i < list.length; i++) {
            r.refereeIndexInReferrerPlusOne[referrerAA][list[i]] = i + 1;
        }
    }

    function _appendReferrerAccount(ReferrerStorage.Layout storage r, address referrerAA) internal {
        if (r.referrerAccountIndexPlusOne[referrerAA] != 0) return;
        r.referrerAccountList.push(referrerAA);
        r.referrerAccountIndexPlusOne[referrerAA] = r.referrerAccountList.length;
    }

    function _removeReferrerAccount(ReferrerStorage.Layout storage r, address referrerAA) internal {
        _removeFromAddressList(r.referrerAccountList, referrerAA, r.referrerAccountIndexPlusOne);
    }

    function _removeFromAddressList(
        address[] storage list,
        address account,
        mapping(address => uint256) storage indexPlusOne
    ) internal {
        uint256 idxPlusOne = indexPlusOne[account];
        if (idxPlusOne == 0) return;
        _removeFromAddressListAtIndex(list, idxPlusOne - 1);
        delete indexPlusOne[account];
        for (uint256 i = 0; i < list.length; i++) {
            indexPlusOne[list[i]] = i + 1;
        }
    }

    function _removeFromAddressListAtIndex(address[] storage list, uint256 idx) internal {
        uint256 lastIdx = list.length - 1;
        if (idx > lastIdx) return;
        if (idx != lastIdx) {
            list[idx] = list[lastIdx];
        }
        list.pop();
    }

    function _pageAddressArray(address[] storage arr, uint256 offset, uint256 pageSize)
        private
        view
        returns (address[] memory page, uint256 total, uint256 nextOffset)
    {
        total = arr.length;
        uint256 capped = pageSize > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : pageSize;
        uint256 start = offset > total ? total : offset;
        uint256 end = start + capped;
        if (end > total) end = total;
        page = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = arr[i];
        }
        nextOffset = end;
    }
}
